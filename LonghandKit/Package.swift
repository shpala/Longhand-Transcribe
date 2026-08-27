// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "LonghandKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "LonghandKit", targets: ["LonghandKit"])
    ],
    targets: [
        .target(name: "LonghandKit"),
        // A developer's measurement, not a shipped feature: it reads a pulled
        // library and reports what the corrections in it say about accuracy.
        // Lives here because it needs nothing but the deterministic core.
        .executableTarget(name: "longhand-accuracy", dependencies: ["LonghandKit"]),
        .testTarget(name: "LonghandKitTests", dependencies: ["LonghandKit"]),
    ]
)
