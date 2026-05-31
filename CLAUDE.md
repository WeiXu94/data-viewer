# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Native macOS **read-only** viewer for Stata `.dta` files. A portable C core (parsing via vendored ReadStat) feeds a Swift/AppKit `NSTableView` front end. `plan.md` is the original spec; consult it for goals/non-goals and the phased build plan, but note the actual layout diverges from it (see below).

## Commands

```sh
swift build                                   # build all targets (debug)
swift test                                     # run the XCTest suite
swift test --filter DtaCoreTests/testAutoMetadataAndFetch   # single test
swift run dta-inspect tests/fixtures/auto.dta 5   # CLI smoke test, prints meta + N rows
swift run DataViewer tests/fixtures/auto.dta      # run the GUI from the package
./scripts/build-app.sh                            # assemble .build/app/DataViewer.app (release)
```

`auto.dta` (74 obs × 12 vars) is the canonical fixture; test expectations are hard-coded against it.

## Architecture

Three layers, each in its own SwiftPM target:

1. **ReadStat** (`core/readstat/`) — vendored MIT C library (Evan Miller), only the Stata/`.dta` subset is wired up. Do not edit; treat as upstream.
2. **DtaCore** (`core/src/dta_core.c`, `core/include/dta_core.h`) — the only ReadStat consumer. Exposes a small, stable C API and **owns all caching and formatting**. Built as a C module (`import DtaCore` from Swift — there is **no bridging header**, despite what `plan.md` suggests).
3. **Swift executables** sharing DtaCore:
   - `DataViewer` (`app/`) — AppKit GUI: `main.swift` → `AppDelegate` → `MainWindowController` → `TableViewController` (the `NSTableView` data source). `DtaDocument.swift` is the Swift wrapper over the C handle.
   - `dta-inspect` (`tools/DtaInspect/`) — CLI dump, useful for verifying core behavior without the UI.
   - `DtaQuickLookPreview` (`quicklook/`) — Quick Look extension rendering an HTML preview.

### Key design contracts (read before touching the C/Swift boundary)

- **Display strings over the FFI.** `dta_fetch` returns cells as already-formatted `char*` strings (row-major, `count * col_count`), never typed values. A `NULL` cell = Stata missing value. Numeric formatting (decimals from the Stata format, comma grouping) happens in C in `dta_format_numeric` / `dta_add_commas`. Keep type/missing-value logic on the C side.
- **The cache lives in C, not Swift.** DtaCore keeps a mutex-guarded LRU of fixed 1000-row chunks (`DTA_CHUNK_SIZE`, `DTA_CACHE_CAPACITY` in `dta_core.c`). `DtaDocument` also batches by 1000 (`swiftChunkSize`) — these two constants are independent and must stay aligned. UI random-scrolling stays smooth because arbitrary row requests resolve against cached chunks.
- **ReadStat parsers are not reentrant.** Every fetch spins up a fresh parser with `readstat_set_row_offset`/`row_limit`; `dta_fetch` serializes via the doc's `pthread_mutex`. Never share a parser across threads.
- **Error code sign convention** (`dta_error_message`): negative codes are DtaCore's own (`DTA_CORE_ERROR_*`); positive codes are passed straight through to `readstat_error_message`.
- **Ownership:** free chunks with `dta_chunk_free`, docs with `dta_close`. Swift wrappers (`DtaDocument`, the inspect/quicklook code) handle this in `deinit`/`defer`.

## App bundle & Quick Look

`scripts/build-app.sh` release-builds `DataViewer` + `DtaQuickLookPreview`, lays out `DataViewer.app` with the `.appex` embedded under `Contents/PlugIns/`, copies the two `Info.plist`s from `resources/`, and ad-hoc codesigns both. The Quick Look extension only activates after macOS registers the built `.app` (e.g. it lives in `/Applications` or has been launched). UTI/content-type wiring lives in `resources/Info.plist` (`com.stata.dta`, `com.stata.stata.data`) and the appex `Info.plist`.

The extension is a SwiftPM executable, so it can't be a normal app extension — `quicklook/ExtensionMain.swift` bridges to the ObjC extension entry point via `@_silgen_name("NSExtensionMain")`. Preview HTML is generated in `DtaPreviewProvider.swift`.
