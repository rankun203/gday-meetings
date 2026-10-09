// swift-tools-version: 6.2

import Foundation
import PackageDescription

#if arch(arm64)
    let audioArchitecture = "arm64"
#else
    let audioArchitecture = "x86_64"
#endif
// The Make entry points build checksum-pinned static libraries with CLT first.
let audioRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(".build/native-audio-\(audioArchitecture)/install").path

let searchRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent(".build/native-search-\(audioArchitecture)/install").path

let package = Package(
    name: "GdayMeetings",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "GdayMeetings", targets: ["GdayMeetings"])],
    dependencies: [
        .package(
            url: "https://github.com/FluidInference/FluidAudio.git",
            revision: "21493f8dac5a97e65742e6ff26f42f164c2fda0f", traits: []),
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            revision: "c21fdcde390313a6d98d8e33a346f2c3486c3ab0"),
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .systemLibrary(name: "USearchC"),
        .target(name: "AudioCaptureBridge", publicHeadersPath: "include"),
        .target(
            name: "OpusFileBridge", publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-I", audioRoot + "/include", "-I", audioRoot + "/include/opus"])],
            linkerSettings: [
                .unsafeFlags([
                    audioRoot + "/lib/libopusfile.a", audioRoot + "/lib/libopus.a", audioRoot + "/lib/libogg.a",
                ])
            ]),
        .executableTarget(
            name: "GdayMeetings",
            dependencies: [
                "AudioCaptureBridge", "OpusFileBridge", "CSQLite", "USearchC",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            resources: [
                .copy("Resources/index.db.template.md"), .copy("Resources/frequent-words.json"),
                .copy("Resources/wordfreq-NOTICE.md"),
                .copy("Resources/meeting-export.html"),
            ], linkerSettings: [.unsafeFlags([searchRoot + "/lib/libsemanticsearch.a"]), .linkedLibrary("c++")]),
        .testTarget(
            name: "GdayMeetingsTests", dependencies: ["GdayMeetings", "AudioCaptureBridge"]),
    ],
    swiftLanguageModes: [.v5]
)
