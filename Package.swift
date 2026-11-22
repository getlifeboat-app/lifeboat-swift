// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LifeboatKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "LifeboatKit", targets: ["LifeboatKit"]),
    ],
    targets: [
        .target(name: "LifeboatKit", resources: [.copy("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "LifeboatKitTests", dependencies: ["LifeboatKit"]),
    ]
)
