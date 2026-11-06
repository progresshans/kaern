// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "KaernKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "KaernKit", targets: ["KaernKit"]),
    ],
    targets: [
        .target(name: "KaernKit"),
        .testTarget(name: "KaernKitTests", dependencies: ["KaernKit"]),
    ]
)
