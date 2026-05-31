# Data‑grid rendering: technical decision record

Date: 2026‑05‑31
Scope: how DataViewer renders the data table, why the original approach was slow,
and the move from a view‑based `NSTableView` to a custom‑drawn grid.
Status: custom grid landed as a working prototype (`app/DataGridView.swift`).

---

## 1. Problem

Scrolling the data table felt laggy, badly so on a real dataset
(`Vietnam-2009-full-data.dta`). The goal: get close to the buttery scrolling of
Stata's Data Browser / Excel / Numbers.

## 2. What we measured (don't guess — profile)

Test file: `tests/fixtures/Vietnam-2009-full-data.dta`.

| Fact | Value | How |
|---|---|---|
| Dimensions | **1,053 rows × 287 columns** | `dta-inspect` |
| File size | 1.1 MB | `ls` |
| Chunks (1000‑row) | **2** (rows 0–999, 1000–1052) | derived |
| Format one 1000×287 chunk | **~80 ms** | `time dta-inspect … 1000` |
| Open + metadata only | ~7 ms | `time dta-inspect … 0` |
| Whole file fully cached | **~160 ms** (2 chunks) | derived |
| ReadStat random access | **O(1) seek**, not a scan | `readstat_dta_read.c:667` `io->seek(record_len * row_offset, SEEK_CUR)` |

**Key conclusion:** the file is *wide and short*. After a one‑time ~160 ms
warmup the entire dataset is in the cache, so **scrolling does zero data
fetching**. The lag was therefore **not** the data layer — it was the cost of
rendering 287 columns with `NSTableView`.

## 3. Where the rendering cost was (view‑based NSTableView)

The original data table was a view‑based `NSTableView`. Three concrete costs,
in order of impact:

1. **`tableView(_:heightOfRow:)` implemented.** Even returning a constant forces
   NSTableView into *variable‑height* mode — it tracks per‑row heights instead
   of `total = rowCount × rowHeight`. This is the single biggest scrolling
   penalty on large tables.
2. **Auto Layout inside every cell.** Each cell pinned its `NSTextField` with
   constraints, so the constraint solver ran per visible cell during scroll.
3. **Per‑cell font lookups.** `monospacedSystemFont(…)` / `systemFont(…)` were
   set on every cell reuse.

Fundamentally, view‑based `NSTableView` instantiates a real `NSView`
(`NSTableCellView` + `NSTextField`) per visible cell. Convenient, but heavy when
hundreds of columns are in play.

## 4. Options considered

### 4a. Is there a better high‑level AppKit view? — No
| Candidate | Verdict |
|---|---|
| **NSGridView** | Static *form‑layout* container, not virtualized. Worse for big data. |
| **NSCollectionView** | Heavier per item than NSTableView (arbitrary layouts). |
| **NSTableView, cell‑based (`NSCell`)** | Lighter than view‑based (flyweight cells, drawn not instantiated) but still carries the table's column machinery; legacy API. |
| **Custom `NSView` with `draw(_:)`** | Draw only visible cells, no per‑cell objects. **Chosen.** |

The win is to go *lower level*, not to find a higher‑level view.

### 4b. Data‑layer ideas that were raised and rejected (for this case)

- **Shrink the 1000‑row chunk to ~50.** Counterproductive here:
  - Total formatting work is independent of chunk size; smaller chunks only add
    parser‑setup overhead and more cache misses.
  - For a 1,053‑row file: 50‑row chunks → ~22 chunks, but the C LRU holds 12 →
    chunks get evicted and re‑parsed *during* scroll. Worse, not better.
  - The valid kernel of the idea — "don't do work for cells you don't show" — is
    about **lazy per‑cell formatting** (we currently eagerly format all 287
    columns), not chunk size.
- **mmap the whole file.** Won't help here:
  - The file is 1.1 MB; the OS **page cache** already keeps it resident after the
    first read.
  - ReadStat already **seeks** directly to any row (O(1)); random access is not a
    scan.
  - The cost is **decoding + formatting + drawing**, none of which mmap changes.
  - mmap + a hand‑rolled fixed‑width decoder only pays off for multi‑GB files
    (zero‑copy random access). Not our situation.

## 5. Decision

Two‑step change:

1. **Interim hardening of the view‑based table** (kept for the sidebar):
   fixed `rowHeight` + no `heightOfRow`, frame‑based cell layout
   (`GridCellView`, positions its text field in `layout()`), cached fonts.
   Helped, but didn't reach "smooth" with 287 columns.

2. **Custom‑drawn grid** for the data area (`app/DataGridView.swift`):
   - `DataGridView: NSView` (`isFlipped`, `isOpaque`) overrides `draw(_:)` and
     paints **only the cells intersecting the dirty rect**, reading display
     strings straight from the in‑memory cache. No per‑cell views.
   - `DataGridHeaderView` is a pinned column header that tracks horizontal
     scroll via an `xOffset` updated from the scroll view's
     `boundsDidChangeNotification`.
   - Uniform 24 pt rows → O(1) geometry; alternating row backgrounds, grid
     lines, right‑aligned numerics, all drawn directly.
   - The **sidebar** (variable list) stays an `NSTableView` — it's small and not
     perf‑critical.

This is the same architectural level Stata/Excel/Numbers operate at (§7).

## 6. Consequences

**Good**
- Scrolling one row repaints only a thin strip (~a dozen cells drawn), instead
  of creating/configuring an `NSView` per visible cell.
- Cost is independent of total column count — only *visible* cells are touched.

**Costs / not yet done (prototype)**
- No column resize, row selection, or copy.
- Column widths are heuristic from the variable name → long string values can
  truncate. Want content‑aware widths.
- Lazy per‑cell formatting (don't format all 287 columns up front) is still a
  pending data‑layer win.
- `cacheDisplay`‑based snapshot testing can't composite the layer‑backed sidebar
  next to the non‑layer grid (the sidebar looks blank in a full‑window snapshot
  but renders fine on screen and when captured directly). Snapshot each view
  separately when verifying.

## 7. How other apps do it (competitive analysis)

The throughline: **data resident in memory (or paged from a backend) + a
custom‑drawn (or web‑virtualized) grid that paints only the visible viewport.**
None use one OS view per cell for big grids.

| App | Rendering | Data residency | Notes |
|---|---|---|---|
| **Stata** (Data Browser/Editor) | Custom‑drawn grid in Stata's own cross‑platform C/C++ GUI layer | Whole dataset in RAM by design (`use` loads into memory) | Cells painted directly; uniform rows; only the viewport drawn. This is why it feels instant. |
| **Excel for Mac** | Microsoft's own grid engine (shared Office codebase), GPU‑accelerated; **not** AppKit table controls | Workbook model in RAM | Viewport‑only drawing, custom cell layout/format engine, frozen panes, etc. |
| **Numbers** (Apple) | Custom canvas/tile rendering (Core Animation / Metal‑style tiles), cells drawn directly | Document model in RAM | Same pattern: direct drawing, no NSTableView. |
| **RStudio** (`View()`) | Qt app embedding **QtWebEngine**; the data viewer is an **HTML/JS virtualized table** | Data **paged** from the R backend on demand | Doesn't ship the whole frame to the browser; requests row pages as you scroll (virtualized DOM). Different stack, same idea: virtualize + stream. |

Patterns worth copying:
1. Keep the data in memory (we do, via the chunk cache; small files fully fit).
2. Draw only the visible viewport (the custom grid does this).
3. Uniform row height → O(1) geometry (done).
4. Format/decode lazily, ideally only for visible cells (still a TODO).

## 8. Follow‑ups

- Lazy per‑cell formatting (format only displayed cells; biggest remaining
  data‑layer win, helps the initial ~160 ms warmup and very wide files).
- Content‑aware column widths; column resize; row selection + copy.
- Background prefetch of upcoming chunks for *tall* files (this file doesn't need
  it; a 10⁶‑row file would, to avoid a synchronous chunk parse on scroll‑in).
- Consider Core Text + cached `CTLine`s if `NSString.draw` becomes a hotspot.

## 9. Related: Quick Look (separate issue)

Not a rendering decision, recorded here for handoff. The Quick Look preview was
showing a stale/old preview because multiple registered bundles
(`/private/tmp/DtaViewer.app`, `~/.Trash/DtaViewer.app`) claimed the `.dta`
UTI. Cleanup done: removed the `/tmp` bundle, installed the app to
`/Applications`, re‑registered. Remaining blockers (need manual / signing work):
the Trash bundle couldn't be deleted from the sandbox (must empty Trash), and on
macOS 26 the **ad‑hoc‑signed** SwiftPM appex won't register with PluginKit —
reliable registration needs a **Developer ID‑signed / notarized** app.

## 10. Pointers

- `app/DataGridView.swift` — custom grid + header.
- `app/TableViewController.swift` — wiring; sidebar stays `NSTableView`.
- `core/src/dta_core.c` — chunk cache (`DTA_CHUNK_SIZE`, `DTA_CACHE_CAPACITY`).
- `core/readstat/src/stata/readstat_dta_read.c:667` — O(1) row seek.
