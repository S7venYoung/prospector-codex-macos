// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ProspectorCodexMacOS",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ProspectorCodexMacOS", targets: ["ProspectorCodexMacOS"])],
    targets: [.executableTarget(name: "ProspectorCodexMacOS")]
)
