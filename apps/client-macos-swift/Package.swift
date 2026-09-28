// swift-tools-version: 5.9

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

let package = Package(
    name: "GdayMeetings",
    platforms: [.macOS("14.2")],
    products: [.executable(name: "GdayMeetings", targets: ["GdayMeetings"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "AudioCaptureBridge", publicHeadersPath: "include"),
        .target(
            name: "OpusFileBridge", publicHeadersPath: "include",
            cSettings: [.unsafeFlags(["-I", audioRoot + "/include", "-I", audioRoot + "/include/opus"])],
            linkerSettings: [
                .unsafeFlags([
                    audioRoot + "/lib/libopusfile.a", audioRoot + "/lib/libopus.a", audioRoot + "/lib/libogg.a",
                ])
            ]),
        .executableTarget(name: "GdayMeetings", dependencies: ["AudioCaptureBridge", "OpusFileBridge", "CSQLite"]),
        .testTarget(name: "GdayMeetingsTests", dependencies: ["GdayMeetings", "AudioCaptureBridge"]),
    ]
)
