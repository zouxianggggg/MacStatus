// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacStatus",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MacStatus", targets: ["MacStatus"])],
    targets: [
        .executableTarget(name: "MacStatus"),
        .testTarget(name: "MacStatusTests", dependencies: ["MacStatus"])
    ]
)
