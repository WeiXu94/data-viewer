# DataViewer

Native macOS read-only viewer for Stata `.dta`, R `.rds`, and MATLAB `.mat`
files.

The project follows the fetched `plan.md`: C parsers are vendored under `core`,
a small wrapper exposes metadata and windowed display-string rows, and the
Swift/AppKit executable renders the shared grid on demand.

## Build

```sh
swift build
swift test
```

Run the CLI smoke inspector:

```sh
swift run data-inspect tests/fixtures/auto.dta 5
swift run data-inspect tests/fixtures/sample.rds 5
swift run data-inspect tests/fixtures/sample.mat 5
```

Run the AppKit viewer from the package:

```sh
swift run DataViewer tests/fixtures/auto.dta
```

Build a `.app` wrapper:

```sh
./scripts/build-app.sh
```

The app bundle includes a Quick Look preview extension for `.dta`, `.rds`, and
`.mat` files. After macOS registers `DataViewer.app`, Finder can use the
spacebar preview to show the dataset label, dimensions, variables, and the first
rows.

Build a GitHub-release style DMG:

```sh
BUILD_ARCHS="arm64" ARCH_LABEL="arm64" ./scripts/make-dmg.sh
BUILD_ARCHS="arm64 x86_64" ARCH_LABEL="universal" ./scripts/make-dmg.sh
```

GitHub release DMGs are unsigned/not notarized unless you provide a Developer ID
signing identity. After dragging `DataViewer.app` to Applications, users may
need to remove Gatekeeper quarantine:

```sh
xattr -rd com.apple.quarantine /Applications/DataViewer.app
```

## Format Support

- `.dta`: Stata datasets through vendored ReadStat.
- `.rds`: R data frames through vendored librdata. Gzip-compressed and
  uncompressed files are supported; bzip2/xz-compressed RDS files are not linked
  in this build.
- `.mat`: MATLAB v4/v5/v7 MAT files through vendored matio. The viewer supports
  numeric/logical matrices and workspaces with equal-length numeric/logical
  vector variables. MAT v7.3/HDF5 files and MATLAB tables/structs/cells are not
  supported yet.

## Layout

```text
data-viewer/
├── app/                 Swift/AppKit UI
├── core/                C wrapper API and vendored parsers
├── resources/           App bundle metadata
├── scripts/             Build helpers
├── tests/               XCTest coverage and fixture
└── plan.md              Fetched implementation plan
```

ReadStat and librdata are MIT licensed; see `core/readstat/LICENSE` and
`core/librdata/LICENSE`. matio is BSD-2-Clause licensed; see
`core/matio/LICENSE`.
