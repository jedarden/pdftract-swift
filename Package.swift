// swift-tools-version: 5.10
// The swift-tools-version declares the minimum version of Swift required to build this package.
import PackageDescription

let package = Package(
    name: "pdftract-swift",
    platforms: [.macOS(.v13), .linux(.v4)],
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
