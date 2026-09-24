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
        .target(
            name: "UtterKit",
            dependencies: ["UtterCore"],
            path: "Sources/UtterKit",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
            ]
        ),
        .executableTarget(
            name: "Utter",
            dependencies: ["UtterKit"],
            path: "Sources/Utter"
        ),
        .testTarget(
            name: "UtterTests",
            dependencies: ["UtterCore", "UtterKit"],
            path: "Tests/UtterTests"
        ),
    ]
)
