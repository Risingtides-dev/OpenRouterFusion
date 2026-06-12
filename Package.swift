// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenRouterFusion",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "OpenRouterFusion", targets: ["OpenRouterFusion"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(
            name: "OpenRouterFusion",
            dependencies: [],
            resources: [.process("Resources")]
        )
    ]
)
