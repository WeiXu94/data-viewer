// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "DataViewer",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "DataViewer", targets: ["DataViewer"]),
        .executable(name: "dta-inspect", targets: ["DtaInspect"])
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
