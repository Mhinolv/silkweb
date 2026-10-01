// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Silkweb",
    platforms: [.macOS(.v15)],
    targets: [
        // Pure model / storage / markdown logic — no UI, unit-testable.
        .target(name: "SilkwebCore"),
        // SwiftUI + AppKit app.
        .executableTarget(name: "Silkweb", dependencies: ["SilkwebCore"]),
        .testTarget(name: "SilkwebCoreTests", dependencies: ["SilkwebCore"]),
        .testTarget(name: "SilkwebAppTests", dependencies: ["Silkweb"]),
    ],
    swiftLanguageModes: [.v5]
)
