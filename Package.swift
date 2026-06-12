// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "OpenRouterFusion",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OpenRouterFusion", targets: ["OpenRouterFusion"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "OpenRouterFusion",
            dependencies: [],
            resources: [.copy("Resources")]
        )
    ],
    swiftLanguageModes: [.v5]
)
