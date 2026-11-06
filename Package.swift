// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "DGGKit",
    platforms: [.iOS("26.0"), .macOS(.v14)],
    products: [.library(name: "DGGKit", targets: ["DGGKit"])],
    targets: [
        .target(name: "DGGKit", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
