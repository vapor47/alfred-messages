// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "AlfredMessages", platforms: [.macOS(.v13)], products: [.executable(name: "MessagesHelper", targets: ["MessagesHelper"])], targets: [.systemLibrary(name: "CSQLite"), .target(name: "MessagesCore", dependencies: ["CSQLite"]), .executableTarget(name: "MessagesHelper", dependencies: ["MessagesCore"]), .executableTarget(name: "MessagesCoreTests", dependencies: ["MessagesCore", "CSQLite"], path: "Tests/MessagesCoreTests")])
