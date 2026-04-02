// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HotReload",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(
            name: "HotReloadClient",
            targets: ["HotReloadClient"]
        ),
    ],
    targets: [
        .target(
            name: "HotReloadClient"
        ),
    ]
)
