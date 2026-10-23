// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "LocalTranscriptionComparison",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "LocalTranscriptionComparison", targets: ["LocalTranscriptionComparison"])],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "c79c4106b954f81205113c3343e5a7e59a1089b5", traits: []),
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            revision: "9f99b5cb6a907730543823ad271b82532782a899"),
    ],
    targets: [
        .executableTarget(
            name: "LocalTranscriptionComparison",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ])
    ],
    swiftLanguageModes: [.v5]
)
