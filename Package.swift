// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Coverwall",
    platforms: [.macOS("14.6")],
    products: [
        .library(name: "CoverwallKit", targets: ["CoverwallKit"]),
    ],
    targets: [
        .target(name: "CoverwallKit"),
        .testTarget(name: "CoverwallKitTests", dependencies: ["CoverwallKit"]),
    ]
)
