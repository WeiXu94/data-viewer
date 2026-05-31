# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Native macOS **read-only** viewer for Stata `.dta`, R `.rds`, and MATLAB `.mat` files. A portable C core (parsing via vendored ReadStat, librdata, and matio) feeds a Swift/AppKit table front end. `plan.md` is the original Stata-only spec; consult it for the initial goals/non-goals and phased build plan, but note the actual layout now diverges from it (see below).

## Commands

```sh
swift build                                   # build all targets (debug)
swift test                                     # run the XCTest suite
swift test --filter DataCoreTests/testAutoMetadataAndFetch   # single test
swift run data-inspect tests/fixtures/auto.dta 5   # CLI smoke test, prints meta + N rows
swift run data-inspect tests/fixtures/sample.rds 5 # RDS smoke test
swift run data-inspect tests/fixtures/sample.mat 5 # MAT smoke test
swift run DataViewer tests/fixtures/auto.dta      # run the GUI from the package
./scripts/build-app.sh                            # assemble .build/app/DataViewer.app (release)
```

`auto.dta` (74 obs × 12 vars) is the canonical Stata fixture; `sample.rds` and `sample.mat` cover the RDS/MAT paths.

## Architecture

Three layers, each in its own SwiftPM target:

1. **Vendored C parsers**:
   - **ReadStat** (`core/readstat/`) — vendored MIT C library (Evan Miller), Stata/`.dta` path.
   - **librdata** (`core/librdata/`) — vendored MIT C library for R data frames in `.rds`; this build links zlib only, so bzip2/xz RDS compression is unsupported.
   - **matio** (`core/matio/`) — vendored BSD-2-Clause C library for MATLAB MAT v4/v5/v7 numeric/logical arrays; MAT v7.3/HDF5 is not enabled.
2. **DataCore** (`core/src/data_core.c`, `core/include/data_core.h`) — the only parser consumer for all supported formats. Exposes a small, stable C API and **owns all caching and formatting**. Built as a C module (`import DataCore` from Swift — there is **no bridging header**, despite what `plan.md` suggests).
3. **Swift executables** sharing DataCore:
   - `DataViewer` (`app/`) — AppKit GUI: `main.swift` → `AppDelegate` → `MainWindowController` → `TableViewController` (the `NSTableView` data source). `DataDocument.swift` is the Swift wrapper over the C handle.
   - `data-inspect` (`tools/DataInspect/`) — CLI dump, useful for verifying core behavior without the UI.
   - `DataViewerQuickLookExtension` (`quicklook/`) — Quick Look extension rendering an HTML preview.

### Key design contracts (read before touching the C/Swift boundary)

- **Display strings over the FFI.** `data_fetch` returns cells as already-formatted `char*` strings (row-major, `count * col_count`), never typed values. A `NULL` cell = missing/blank. Numeric and missing-value logic stays on the C side.
- **The cache lives in C, not Swift.** DataCore keeps a mutex-guarded LRU of fixed 1000-row chunks (`DATA_CHUNK_SIZE`, `DATA_CACHE_CAPACITY` in `data_core.c`). `DataDocument` also batches by 1000 (`swiftChunkSize`) — these two constants are independent and must stay aligned. Stata fetches are parser-windowed; RDS/MAT currently materialize supported tables in C memory on open, then serve the same cached chunk API.
- **ReadStat parsers are not reentrant.** Every fetch spins up a fresh parser with `readstat_set_row_offset`/`row_limit`; `data_fetch` serializes via the doc's `pthread_mutex`. Never share a parser across threads.
- **Error code sign convention** (`data_error_message`): negative codes are DataCore's own (`DATA_CORE_ERROR_*`); positive codes are passed straight through to `readstat_error_message`.
- **Ownership:** free chunks with `data_chunk_free`, docs with `data_close`. Swift wrappers (`DataDocument`, the inspect/quicklook code) handle this in `deinit`/`defer`.

## App bundle & Quick Look

`scripts/build-app.sh` release-builds `DataViewer` + `DataViewerQuickLookExtension`, lays out `DataViewer.app` with the `.appex` embedded under `Contents/PlugIns/`, copies the two `Info.plist`s from `resources/`, and signs the app bundle. The Quick Look extension only activates after macOS registers the built `.app` (e.g. it lives in `/Applications` or has been launched). UTI/content-type wiring lives in `resources/Info.plist` and the appex `Info.plist` for Stata `.dta`, R `.rds`, and MATLAB `.mat`.

The extension is a SwiftPM executable, so it can't be a normal app extension — `quicklook/ExtensionMain.swift` bridges to the ObjC extension entry point via `@_silgen_name("NSExtensionMain")`. Preview HTML is generated in `DataPreviewProvider.swift`.
