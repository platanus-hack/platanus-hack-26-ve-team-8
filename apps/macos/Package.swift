// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Guardian",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "Guardian", targets: ["Guardian"])],
    targets: [.executableTarget(name: "Guardian")]
)
