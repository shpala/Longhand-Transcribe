// swift-tools-version: 6.0
import PackageDescription

// The OS-coupled but cross-platform middle layer: inference engines, audio
// normalization, format adapters, import, and pipeline orchestration.
// Shared by the iOS app and (planned) macOS app. Pure logic stays in
// LonghandKit; platform shells (recording sessions, background execution,
// SwiftUI) stay in the app targets.
let package = Package(
    name: "LonghandEngines",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "LonghandEngines", targets: ["LonghandEngines"]),
    ],
    dependencies: [
        .package(path: "../LonghandKit"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.1.0"),
    ],
    targets: [
        .target(
            name: "LonghandEngines",
            dependencies: [
                .product(name: "LonghandKit", package: "LonghandKit"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "SpeakerKit", package: "argmax-oss-swift"),
            ],
            resources: [
                // Attribution texts for the vendored models and libraries;
                // bundled with the layer that depends on them, so every shell
                // ships the same set (§4.3 audit).
                .copy("Resources/Licenses"),
                // The Community-1 diarization models (11 MB), shipped rather
                // than fetched. `.copy` and not `.process`: these are compiled
                // `.mlmodelc` directories and must reach the bundle byte for
                // byte, with their nesting intact.
                .copy("Resources/SpeakerModels"),
            ]
        ),
        // Pipeline-level tests that need no audio and no models: seeding the
        // ASR and diarization checkpoints makes `run()` skip straight to
        // merge → identify → export, which is the path every overlay feature
        // depends on.
        .testTarget(
            name: "LonghandEnginesTests",
            dependencies: ["LonghandEngines"]
        ),
    ]
)
