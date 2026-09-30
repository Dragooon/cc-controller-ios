// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "CCKit",
    platforms: [
        .iOS(.v27),
        .macOS(.v26)
    ],
    products: [
        .library(name: "CCKit", targets: ["CCKit"])
    ],
    targets: [
        .target(name: "CCKit"),
        .testTarget(name: "CCKitTests", dependencies: ["CCKit"], resources: [.process("Fixtures")])
    ]
)
