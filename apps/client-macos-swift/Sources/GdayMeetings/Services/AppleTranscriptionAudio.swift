import AVFoundation
import Foundation

/// File extensions describe containers, not whether Apple's decoder can read every packet.
/// Native files use Apple decoding; Ogg Opus uses the bundled playback decoder.
enum AppleTranscriptionAudio {
    static func findFFmpeg() -> URL? {
        let paths =
            ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").components(separatedBy: ":")
        return paths.filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: $0).appendingPathComponent("ffmpeg")
        }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Read in bounded buffers before starting recognition. Opening a file alone is insufficient.
    static func validate(_ url: URL) throws {
        try Task.checkCancellation()
        if ["opus", "ogg"].contains(url.pathExtension.lowercased()) {
            let reader = try OpusFileDecoder(url)
            guard reader.totalFrames > 0,
                let buffer = AVAudioPCMBuffer(pcmFormat: StreamingAudioReader.format, frameCapacity: 8192)
            else { throw ServiceError("This recording has no readable audio samples.") }
            var frames: Int64 = 0
            while true {
                try Task.checkCancellation()
                try reader.read(into: buffer, frames: buffer.frameCapacity)
                if buffer.frameLength == 0 { break }
                frames += Int64(buffer.frameLength)
            }
            guard frames == reader.totalFrames else {
                throw ServiceError("The audio ended before the recording was complete.")
            }
            return
        }
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard file.length > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 8192)
        else { throw ServiceError("This recording has no readable audio samples.") }
        var frames: AVAudioFramePosition = 0
        // Avoid framePosition: some malformed compressed files raise an Objective-C exception there.
        while frames < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(8192, file.length - frames)))
            guard buffer.frameLength > 0 else {
                throw ServiceError("The audio ended before the recording was complete.")
            }
            frames += AVAudioFramePosition(buffer.frameLength)
        }
    }

    static func prepare(
        _ source: URL, ffmpeg: URL? = findFFmpeg(),
        status: @escaping @Sendable (String) async -> Void
    ) async throws -> PreparedPlaybackAudio {
        // Preserve filesystem errors rather than describing a missing file as a codec problem.
        _ = try source.resourceValues(forKeys: [.fileSizeKey])
        await status("Checking audio for transcription…")
        do {
            try validate(source)
            return .init(url: source, temporary: false)
        }
        catch {
            try Task.checkCancellation()
            guard let ffmpeg else { throw failure(error, conversion: .unavailable) }
            await status("Converting audio for transcription…")
            // A container repair can preserve the original compressed audio. Accept it only after decoding.
            for copy in [true, false] {
                let destination = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "gday-transcription-\(UUID().uuidString).\(copy ? "m4a" : "opus")")
                var retained = false
                defer { if !retained { try? FileManager.default.removeItem(at: destination) } }
                guard
                    FileManager.default.createFile(
                        atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600])
                else {
                    throw ServiceError("Couldn’t create temporary audio. Check available disk space and try again.")
                }
                do {
                    try await convert(source, to: destination, executable: ffmpeg, copy: copy)
                    try validate(destination)
                    retained = true
                    return .init(url: destination, temporary: true)
                }
                catch {
                    try Task.checkCancellation()
                }
            }
            throw failure(error, conversion: .failed)
        }
    }

    enum Conversion { case unavailable, failed }

    static func failure(_ error: Error, conversion: Conversion) -> ServiceError {
        let underlying = error as NSError
        let recovery =
            conversion == .unavailable
            ? "FFmpeg wasn’t found on this Mac. Install FFmpeg and choose Resume, or import a PCM WAV or AIFF copy."
            : "FFmpeg couldn’t create readable audio. Import a PCM WAV or AIFF copy, or obtain a new recording."
        return ServiceError(
            "This Mac couldn’t decode the recording for transcription. The audio encoding or container may be unsupported or damaged. "
                + recovery + " (\(underlying.domain), \(underlying.code).)")
    }

    private static func convert(_ source: URL, to destination: URL, executable: URL, copy: Bool) async throws {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        var arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-xerror", "-y",
            "-protocol_whitelist", "file,pipe", "-i", source.path, "-map", "0:a:0", "-vn",
            "-map_metadata", "-1", "-c:a", copy ? "copy" : "libopus",
        ]
        if !copy {
            arguments += [
                "-ar", "48000", "-af", "aformat=channel_layouts=mono|stereo", "-b:a", "64k", "-application", "voip",
            ]
        }
        arguments.append(destination.path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        // Do not retain media paths or arbitrary decoder output in task history.
        process.standardError = FileHandle.nullDevice
        try process.run()
        do {
            while process.isRunning {
                try await Task.sleep(for: .milliseconds(100))
            }
            try Task.checkCancellation()
        }
        catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ServiceError("Audio conversion failed.")
        }
    }
}
