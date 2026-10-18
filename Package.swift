// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Coverwall",
    platforms: [.macOS("14.6")],
    products: [
        .library(name: "CoverwallKit", targets: ["CoverwallKit"]),
        .executable(name: "coverwall", targets: ["coverwall"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.0"),
    ],
    targets: [
        .target(name: "CoverwallKit"),
        .executableTarget(name: "coverwall", dependencies: [
            "CoverwallKit",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
        ]),
        // Depends on `coverwall` so the end-to-end tests can run the built binary.
        .testTarget(name: "CoverwallKitTests", dependencies: ["CoverwallKit", "coverwall"]),
    ]
)
