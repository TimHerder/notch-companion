// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "NotchCompanion",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "NotchCompanion", targets: ["NotchCompanion"])],
    dependencies: [
        // Parakeet dictation only: no traits keeps out text-to-speech, diarization
        // and the prebuilt text-normalization binary.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.3", traits: []),
    ],
    targets: [
        .executableTarget(name: "NotchCompanion",
                          dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
                          resources: [.process("Resources")]),
        .testTarget(name: "NotchCompanionTests",
                    dependencies: ["NotchCompanion", .product(name: "FluidAudio", package: "FluidAudio")])
    ],
    swiftLanguageModes: [.v5]
)
