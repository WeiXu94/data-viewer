// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DataViewer",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "DataViewer", targets: ["DataViewer"]),
        .executable(name: "data-inspect", targets: ["DataInspect"]),
        .executable(name: "DataViewerQuickLookExtension", targets: ["DataViewerQuickLookExtension"])
    ],
    targets: [
        .target(
            name: "ReadStat",
            path: "core/readstat",
            exclude: ["LICENSE"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .headerSearchPath("src/stata")
            ],
            linkerSettings: [
                .linkedLibrary("iconv")
            ]
        ),
        .target(
            name: "DataCore",
            dependencies: ["ReadStat"],
            path: "core",
            exclude: ["readstat"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
                .headerSearchPath("librdata/src"),
                .headerSearchPath("matio/src"),
                .define("HAVE_ZLIB", to: "1"),
                .define("HAVE_BZIP2", to: "0"),
                .define("HAVE_APPLE_COMPRESSION", to: "0"),
                .define("HAVE_LZMA", to: "0")
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedLibrary("iconv"),
                .linkedLibrary("m")
            ]
        ),
        .executableTarget(
            name: "DataViewer",
            dependencies: ["DataCore"],
            path: "app",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .executableTarget(
            name: "DataInspect",
            dependencies: ["DataCore"],
            path: "tools/DataInspect"
        ),
        .executableTarget(
            name: "DataViewerQuickLookExtension",
            dependencies: ["DataCore"],
            path: "quicklook",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .testTarget(
            name: "DataCoreTests",
            dependencies: ["DataCore"],
            path: "tests",
            exclude: [
                "fixtures/Vietnam-2009-full-data.dta"
            ],
            resources: [
                .copy("fixtures/auto.dta"),
                .copy("fixtures/sample.rds"),
                .copy("fixtures/sample.mat")
            ]
        )
    ]
)
