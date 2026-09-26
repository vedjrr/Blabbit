// swift-tools-version:6.0
import PackageDescription

// The Rust core is prebuilt by `make core` into core/target/release/libblabbit_ffi.a
// and its UniFFI bindings are generated into Sources/BlabbitFFI + Sources/BlabbitCore.
let rustLib = "../core/target/release"

let package = Package(
    name: "Blabbit",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Blabbit", targets: ["Blabbit"]),
    ],
    dependencies: [
        // History (SQLite + FTS5), ADR-009. MIT.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // Updates (G7), ADR-011. MIT.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "BlabbitFFI",
            path: "Sources/BlabbitFFI",
            linkerSettings: [
                .unsafeFlags(["-L\(rustLib)"]),
                .linkedLibrary("blabbit_ffi"),
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
            name: "BlabbitCore",
            dependencies: ["BlabbitFFI"],
            path: "Sources/BlabbitCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Catches AVAudioEngine's Objective-C exceptions, which Swift can't.
        .target(
            name: "BlabbitObjC",
            path: "Sources/BlabbitObjC"
        ),
        .target(
            name: "BlabbitKit",
            dependencies: ["BlabbitCore", "BlabbitObjC", .product(name: "GRDB", package: "GRDB.swift"), .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/BlabbitKit",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "Blabbit",
            dependencies: ["BlabbitKit"],
            path: "Sources/Blabbit",
            // Sparkle.framework is embedded in Contents/Frameworks (see `make bundle`).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // `make bench`: measures the real app, models, capture and insertion (never bundled).
        .executableTarget(
            name: "blabbit-bench",
            dependencies: ["BlabbitKit", "BlabbitCore"],
            path: "Sources/BlabbitBench"
        ),
        // Test-only helper app hosting real AppKit text controls (never bundled).
        .executableTarget(
            name: "BlabbitAXHost",
            path: "Sources/BlabbitAXHost"
        ),
        .testTarget(
            name: "BlabbitTests",
            dependencies: ["BlabbitCore", "BlabbitKit", "BlabbitObjC"],
            path: "Tests/BlabbitTests"
        ),
    ]
)
