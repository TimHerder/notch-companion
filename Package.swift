// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NotchCompanion",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "NotchCompanion", targets: ["NotchCompanion"])],
    targets: [
        .executableTarget(name: "NotchCompanion", resources: [.process("Resources")]),
        .testTarget(name: "NotchCompanionTests", dependencies: ["NotchCompanion"])
    ]
)
