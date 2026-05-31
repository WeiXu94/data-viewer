# Plan: Native macOS `.dta` Viewer

A lightweight macOS app to open and browse Stata `.dta` datasets. **Read-only viewer**, not an editor. Built as a portable **C core** (parsing, backed by the ReadStat C library) feeding a **Swift + AppKit** front end (`NSTableView`).

---

## 1. Goals & non-goals

**Goals**
- Open a `.dta` file and display it as a scrollable table.
- Show variable (column) names and labels as headers; dataset label + row/var counts in a status area.
- Handle large files smoothly (hundreds of thousands to millions of rows) via windowed reads — never load the whole dataset into memory.
- Correct handling of Stata quirks: missing-value sentinels, `strL` long strings, byte order, format codes — delegated to ReadStat.

**Non-goals (out of scope for v1)**
- Editing, writing, or converting `.dta` files.
- Statistics, charts, regressions.
- SAS/SPSS formats (ReadStat supports them, but keep v1 focused on `.dta`).

---

## 2. Architecture

```text
┌───────────────────────────────────────────┐
│  Swift / AppKit  (UI layer)               │
│   NSWindow → NSSplitView                  │
│     └ NSScrollView → NSTableView          │
│         data source: "give me rows i..j"  │
└──────────────────┬────────────────────────┘
                   │  bridging header (Swift imports C directly)
┌──────────────────▼────────────────────────┐
│  C core  (dta_core.c / dta_core.h)        │
│   - open + parse metadata (cached)        │
│   - windowed fetch via offset/limit       │
│   - LRU chunk cache                       │
└──────────────────┬────────────────────────┘
                   │  links
┌──────────────────▼────────────────────────┐
│  ReadStat  (C library, MIT, Evan Miller)  │
│   github.com/WizardMac/ReadStat           │
└───────────────────────────────────────────┘
```

**Why this split**
- ReadStat is C; Swift imports C headers cleanly via a bridging header, so no FFI shim is needed (unlike Rust).
- Keeping the core in **plain C** (not ObjC) keeps it portable — a future iOS/UIKit front end could reuse it unchanged.
- All ReadStat interaction lives in one file; the Swift side only ever calls our small wrapper API.

---

## 3. Dependencies

- **ReadStat** — vendor the source from `github.com/WizardMac/ReadStat` (MIT). Either add the `.c`/`.h` sources directly to the Xcode target, or build a static lib and link it. Avoid a system-wide install so the build is self-contained.
- **Xcode** project, macOS target (deployment target macOS 12+ is fine).
- No Rust, no third-party Swift packages required for v1.

---

## 4. C core API (our wrapper — `dta_core.h`)

This is the contract the Swift layer depends on. Keep it small and stable. For a viewer, return cells as **pre-formatted display strings** to avoid exposing ReadStat's full type/missing-value zoo across the boundary.

```c
typedef struct DtaDoc DtaDoc;

typedef enum { DTA_NUMERIC, DTA_STRING } DtaColType;

typedef struct {
    int32_t     index;
    char       *name;     // variable name
    char       *label;    // variable label (may be empty)
    DtaColType  type;
    char       *format;   // Stata display format, e.g. "%9.0g"
} DtaColumn;

typedef struct {
    int64_t     row_count;
    int32_t     col_count;
    DtaColumn  *columns;        // col_count entries
    char       *dataset_label;  // may be empty
} DtaMeta;

typedef struct {
    int64_t   offset;
    int32_t   count;       // rows actually returned (<= requested)
    int32_t   col_count;
    char    **cells;       // count * col_count, row-major; NULL entry = missing
} DtaChunk;

// Open file and parse metadata only (fast). Returns NULL on error; sets *out_err.
DtaDoc        *dta_open(const char *path, int *out_err);
const DtaMeta *dta_metadata(DtaDoc *doc);

// Fetch rows [offset, offset+count). Served from cache when possible.
DtaChunk      *dta_fetch(DtaDoc *doc, int64_t offset, int32_t count);
void           dta_chunk_free(DtaChunk *chunk);

void           dta_close(DtaDoc *doc);
```

**Mapping to ReadStat** (verify exact signatures against `readstat.h`):
- `dta_open`: `readstat_parser_init` → set metadata + variable handlers → `readstat_parse_dta` with the parser configured for metadata only (limit rows to 0). Cache `DtaMeta` from `readstat_get_row_count` / `readstat_get_var_count` and the per-variable name/label/type/format accessors.
- `dta_fetch`: configure a parser with `readstat_set_row_offset(parser, offset)` and `readstat_set_row_limit(parser, count)`, set a value handler that writes each cell (formatted) into the `DtaChunk` buffer, then `readstat_parse_dta`.
- Missing values: check `readstat_value_is_missing` in the value handler; emit `NULL` (UI renders blank or `.`).
- Value labels: register a value-label handler now so a later feature can map codes → text; store the label sets on the `DtaDoc`.

---

## 5. Chunk cache (inside the C core)

Random scrolling against a streaming parser needs caching. Put it in the core so Swift stays trivial.

- Fetch in fixed **chunks larger than the viewport** (e.g. 1,000 rows). A request for rows `i..j` maps to the chunk(s) covering them.
- Keep a small **LRU** of recent chunks (e.g. 8–16 chunks).
- On cache miss, parse the chunk via offset/limit, store, return the requested slice.

> **Profile the offset behavior.** ReadStat's `row_offset` is documented as "skip N rows," which is not guaranteed to be an O(1) seek. For fixed-width uncompressed `.dta` it should seek directly, but if jumping to deep offsets in a huge file turns out to scan, build a one-time byte-offset index on open and seek with that instead. Decide this with a measurement, not upfront.

---

## 6. Threading

- ReadStat parsers are **not reentrant** — never share one parser across threads, and serialize `dta_fetch` (a serial dispatch queue or a mutex inside the core).
- `NSTableView` calls its data source on the **main thread**. For smooth scroll: prefetch the chunk for the visible range on a background queue, populate the cache, then `reloadData` (or reload visible rows) on the main thread.
- v1 acceptable simplification: synchronous `dta_fetch` from cache on the main thread, with background prefetch of adjacent chunks. Optimize only if scrolling stutters.

---

## 7. Swift / AppKit layer

- **Bridging header** exposes `dta_core.h` to Swift. Wrap the C API in a small Swift class (`DtaDocument`) that owns the `DtaDoc *`, vends `meta`, and offers `cell(row:col:) -> String?` backed by `dta_fetch`.
- **Window**: `NSWindow` → `NSSplitView` (sidebar reserved for a future file list / variable browser) → `NSScrollView` → `NSTableView`.
- **Columns**: built dynamically from `DtaMeta` — one `NSTableColumn` per variable. Header shows the variable name; tooltip (or a second header line) shows the variable label. Right-align numeric columns, left-align strings.
- **Data source**: implement `numberOfRows(in:)` from `meta.row_count` and `tableView(_:objectValueFor:row:)` calling `cell(row:col:)`. This is on-demand — only visible rows are ever requested.
- **Open**: `NSOpenPanel` filtered to `.dta`; also accept a path argument / drag-and-drop.
- **Status area**: `N obs × K vars`, dataset label, file name.

---

## 8. Implementation phases

Each phase is independently testable. Build in order.

| Phase | Deliverable | Acceptance check |
|---|---|---|
| 0 | Xcode project + ReadStat vendored and building | App launches to an empty window; ReadStat compiles & links |
| 1 | `dta_open` + `dta_metadata` | Print row/var counts, names, labels for `auto.dta` to console — matches Stata |
| 2 | `dta_fetch` (offset/limit → display strings) | Fetch rows 0–9 and 100–109; values match Stata's browse |
| 3 | LRU chunk cache in core | Repeated/overlapping fetches hit cache; no correctness change |
| 4 | Bridging header + `DtaDocument` Swift wrapper | Swift unit test reads metadata + a cell range |
| 5 | `NSTableView` + dynamic columns + data source | Open `auto.dta` via panel; scroll the full table |
| 6 | Polish: open panel, drag-drop, labels in headers, status bar, background prefetch | Smooth scroll on a 1M-row file; headers show labels |
| 7 (stretch) | Value-label display toggle, column sort, search/filter | Toggle shows "Male/Female" instead of 1/2 |

---

## 9. Gotchas / decisions already made

- **Display strings over the FFI for v1.** Simpler boundary; revisit only if a feature needs typed values.
- **Missing values** are ReadStat's job — use `readstat_value_is_missing`, render blank/`.`.
- **`strL`** long strings are resolved by ReadStat; no special handling needed in the core.
- **Byte order** is per-file and handled by ReadStat — never assume little-endian.
- **Core stays plain C**, not ObjC, to keep it portable.
- **AppKit from Swift** is fully supported; no Objective-C in this project. (If a contributor prefers ObjC for the UI, the C core is reusable unchanged.)

---

## 10. Test data

- `auto.dta` and `lifeexp.dta` ship with Stata (`sysuse auto`, then `save`). Small, good for correctness.
- Generate a large file (1M+ rows) with `pandas`/`pyreadstat` `write_dta` to test scrolling/cache performance.
- Cross-check displayed values against Stata's data browser or `pyreadstat.read_dta`.

---

## 11. Repo layout (suggested)

```text
data-viewer/
├── core/
│   ├── dta_core.h
│   ├── dta_core.c
│   └── readstat/        # vendored ReadStat sources
├── app/
│   ├── DataViewer-Bridging-Header.h
│   ├── DtaDocument.swift
│   ├── TableViewController.swift
│   └── AppDelegate.swift
├── tests/
└── plan.md
```
