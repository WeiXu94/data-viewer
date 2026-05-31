# DataViewer

Native macOS read-only viewer for Stata `.dta` files.

The project follows the fetched `plan.md`: ReadStat is vendored in `core/readstat`, a small C wrapper in `core` exposes metadata and windowed rows, and the Swift/AppKit executable renders an `NSTableView` on demand.

## Build

```sh
swift build
swift test
```

Run the CLI smoke inspector:

```sh
swift run dta-inspect tests/fixtures/auto.dta 5
```

Run the AppKit viewer from the package:

```sh
swift run DataViewer tests/fixtures/auto.dta
```

Build a `.app` wrapper:

```sh
./scripts/build-app.sh
```

## Layout

```text
data-viewer/
├── app/                 Swift/AppKit UI
├── core/                C wrapper API and vendored ReadStat
├── resources/           App bundle metadata
├── scripts/             Build helpers
├── tests/               XCTest coverage and fixture
└── plan.md              Fetched implementation plan
```

ReadStat is MIT licensed; see `core/readstat/LICENSE`.
