// swift-tools-version:6.0
import PackageDescription

// The Rust core is prebuilt by `make core` into core/target/release/libutter_ffi.a
// and its UniFFI bindings are generated into Sources/UtterFFI + Sources/UtterCore.
let rustLib = "../core/target/release"

let package = Package(
    name: "Utter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Utter", targets: ["Utter"]),
    ],
    dependencies: [
        // History (SQLite + FTS5), ADR-009. MIT.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // Updates (G7), ADR-011. MIT.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "UtterFFI",
            path: "Sources/UtterFFI",
            linkerSettings: [
                .unsafeFlags(["-L\(rustLib)"]),
                .linkedLibrary("utter_ffi"),
                .linkedLibrary("c++"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "UtterCore",
            dependencies: ["UtterFFI"],
            path: "Sources/UtterCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Catches AVAudioEngine's Objective-C exceptions, which Swift can't.
        .target(
            name: "UtterObjC",
            path: "Sources/UtterObjC"
        ),
        .target(
            name: "UtterKit",
            dependencies: ["UtterCore", "UtterObjC", .product(name: "GRDB", package: "GRDB.swift"), .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/UtterKit",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "Utter",
            dependencies: ["UtterKit"],
            path: "Sources/Utter",
            // Sparkle.framework is embedded in Contents/Frameworks (see `make bundle`).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // `make bench`: measures the real app, models, capture and insertion (never bundled).
        .executableTarget(
            name: "utter-bench",
            dependencies: ["UtterKit", "UtterCore"],
            path: "Sources/UtterBench"
        ),
        // Test-only helper app hosting real AppKit text controls (never bundled).
        .executableTarget(
            name: "UtterAXHost",
            path: "Sources/UtterAXHost"
        ),
        .testTarget(
            name: "UtterTests",
            dependencies: ["UtterCore", "UtterKit", "UtterObjC"],
            path: "Tests/UtterTests"
        ),
    ]
)
