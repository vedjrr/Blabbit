// swift-tools-version:6.0
import PackageDescription

// The Rust core is prebuilt by `make core` into core/target/release/libsayless_ffi.a
// and its UniFFI bindings are generated into Sources/SayLessFFI + Sources/SayLessCore.
let rustLib = "../core/target/release"

let package = Package(
    name: "SayLess",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SayLess", targets: ["SayLess"]),
    ],
    dependencies: [
        // History (SQLite + FTS5), ADR-009. MIT.
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
        // Updates (G7), ADR-011. MIT.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .target(
            name: "SayLessFFI",
            path: "Sources/SayLessFFI",
            linkerSettings: [
                .unsafeFlags(["-L\(rustLib)"]),
                .linkedLibrary("sayless_ffi"),
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
            name: "SayLessCore",
            dependencies: ["SayLessFFI"],
            path: "Sources/SayLessCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Catches AVAudioEngine's Objective-C exceptions, which Swift can't.
        .target(
            name: "SayLessObjC",
            path: "Sources/SayLessObjC"
        ),
        .target(
            name: "SayLessKit",
            dependencies: ["SayLessCore", "SayLessObjC", .product(name: "GRDB", package: "GRDB.swift"), .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/SayLessKit",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOKit"),
            ]
        ),
        .executableTarget(
            name: "SayLess",
            dependencies: ["SayLessKit"],
            path: "Sources/SayLess",
            // Sparkle.framework is embedded in Contents/Frameworks (see `make bundle`).
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        // `make bench`: measures the real app, models, capture and insertion (never bundled).
        .executableTarget(
            name: "sayless-bench",
            dependencies: ["SayLessKit", "SayLessCore"],
            path: "Sources/SayLessBench"
        ),
        // Test-only helper app hosting real AppKit text controls (never bundled).
        .executableTarget(
            name: "SayLessAXHost",
            path: "Sources/SayLessAXHost"
        ),
        .testTarget(
            name: "SayLessTests",
            dependencies: ["SayLessCore", "SayLessKit", "SayLessObjC"],
            path: "Tests/SayLessTests"
        ),
    ]
)
