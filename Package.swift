// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Clearline",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ClearlineCore", targets: ["ClearlineCore"]), .executable(name: "Clearline", targets: ["ClearlineApp"])],
    targets: [
        .target(name: "ClearlineCore"),
        .executableTarget(name: "ClearlineApp", dependencies: ["ClearlineCore"]),
        .testTarget(name: "ClearlineCoreTests", dependencies: ["ClearlineCore", "ClearlineApp"])
    ],
    swiftLanguageModes: [.v5]
)
