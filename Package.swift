// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DataViewer",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "DataViewer", targets: ["DataViewer"]),
        .executable(name: "dta-inspect", targets: ["DtaInspect"]),
        .executable(name: "DtaQuickLookPreview", targets: ["DtaQuickLookPreview"])
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
            name: "DtaCore",
            dependencies: ["ReadStat"],
            path: "core",
            exclude: ["readstat"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include")
            ]
        ),
        .executableTarget(
            name: "DataViewer",
            dependencies: ["DtaCore"],
            path: "app",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .executableTarget(
            name: "DtaInspect",
            dependencies: ["DtaCore"],
            path: "tools/DtaInspect"
        ),
        .executableTarget(
            name: "DtaQuickLookPreview",
            dependencies: ["DtaCore"],
            path: "quicklook",
            linkerSettings: [
                .linkedFramework("Foundation"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("UniformTypeIdentifiers")
            ]
        ),
        .testTarget(
            name: "DtaCoreTests",
            dependencies: ["DtaCore"],
            path: "tests",
            resources: [
                .copy("fixtures/auto.dta")
            ]
        )
    ]
)
