// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "QuestBridgeCore", platforms: [.macOS(.v15)],
    products: [.library(name: "QuestBridgeCore", targets: ["QuestBridgeCore"])],
    targets: [.target(name: "QuestBridgeCore", path: "QuestBridge/Core"),
              .testTarget(name: "QuestBridgeCoreTests", dependencies: ["QuestBridgeCore"], path: "Tests/QuestBridgeCoreTests")]
)
