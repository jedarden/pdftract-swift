// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "pdftract-swift",
    // Linux is intentionally absent: SwiftPM enforces no Linux deployment
    // target, and `SupportedPlatform.linux` only exists in SwiftPM 6.0+, so
    // declaring it here broke `swift build` on every Swift 5.10 toolchain
    // (PackageDescription 510 has no such member).
    platforms: [.macOS(.v13)],
    products: [
        .library(
            name: "Pdftract",
            targets: ["Pdftract"])
    ],
    dependencies: [
    ],
    targets: [
        .target(
            name: "PdftractCodegen",
            dependencies: []),
        .target(
            name: "Pdftract",
            dependencies: ["PdftractCodegen"]),
        .testTarget(
            name: "PdftractTests",
            dependencies: ["Pdftract"]),
    ]
)
