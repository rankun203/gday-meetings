import AVFoundation
import Darwin
import Foundation

struct OutputSegment: Codable, Sendable {
    var start: Double
    var end: Double
    var text: String
}

struct AdapterResult: Sendable {
    var segments: [OutputSegment]
    var modelID: String
    var modelRevision: String
    var modelLoadSeconds: Double
    var transcriptionSeconds: Double
    var audioDecodeSeconds: Double? = nil
    var timestampGranularity: String = "segment"
    var diagnostics: [String: Int]? = nil
}

struct ComparisonError: Error, LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct ResourceSnapshot {
    var cpuSeconds: Double
    var peakRSSBytes: Int64
    static func now() -> Self {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return .init(
            cpuSeconds: Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000,
            peakRSSBytes: Int64(usage.ru_maxrss))
    }
}

private struct ComparisonOutput: Encodable {
    var schemaVersion = 1
    var provider: String
    var model: Model
    var language: String
    var segments: [OutputSegment]
    var timing: Timing
    var resources: Resources
    var timestampGranularity: String
    var diagnostics: [String: Int]?
    var status = "completed"
    var timingScope: String
    var operatingSystem: String
    struct Model: Encodable {
        var id: String
        var revision: String
        var runtime: String
    }
    struct Timing: Encodable {
        var modelLoadSeconds: Double
        var audioDecodeSeconds: Double?
        var transcriptionSeconds: Double
        var totalSeconds: Double
    }
    struct Resources: Encodable {
        var cpuSeconds: Double
        var peakRSSBytes: Int64
        var accountingScope: String
    }
}

@main struct LocalTranscriptionComparison {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(
                Data("Transcription failed: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        var arguments: [String: String] = [:]
        var index = 1
        while index < CommandLine.arguments.count {
            let key = CommandLine.arguments[index]
            if key == "--prepare-apple-assets" {
                guard arguments[key] == nil else {
                    throw ComparisonError("Provide the asset setup option once.")
                }
                arguments[key] = "true"
                index += 1
                continue
            }
            if key == "--help" {
                print(
                    "LocalTranscriptionComparison --provider apple|nemotron|whisper --audio PATH --language CODE --output JSON --model-root PATH [--model-revision SHA]\nLocalTranscriptionComparison --prepare-apple-assets --language CODE --output JSON"
                )
                return
            }
            guard
                ["--provider", "--audio", "--language", "--output", "--model-root", "--model-revision"]
                    .contains(key),
                index + 1 < CommandLine.arguments.count, arguments[key] == nil
            else { throw ComparisonError("Provide each supported option once with its value.") }
            arguments[key] = CommandLine.arguments[index + 1]
            index += 2
        }
        func required(_ key: String) throws -> String {
            guard let value = arguments[key], !value.isEmpty else {
                throw ComparisonError("Missing \(key).")
            }
            return value
        }
        if arguments["--prepare-apple-assets"] != nil {
            let report = try await prepareAppleAssets(language: required("--language"))
            let destination = URL(fileURLWithPath: try required("--output"))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: destination, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: destination.path)
            return
        }
        let provider = try required("--provider")
        guard ["apple", "nemotron", "whisper"].contains(provider) else {
            throw ComparisonError("Unknown provider.")
        }
        let audio = URL(fileURLWithPath: try required("--audio"))
        let language = try required("--language")
        let destination = URL(fileURLWithPath: try required("--output"))
        let modelRoot = URL(fileURLWithPath: try required("--model-root"))
        guard audio.standardizedFileURL != destination.standardizedFileURL else {
            throw ComparisonError("The output must differ from the audio input.")
        }
        let start = ProcessInfo.processInfo.systemUptime
        let resources = ResourceSnapshot.now()
        let result: AdapterResult
        switch provider {
        case "apple":
            result = try await transcribeApple(audio: audio, language: language, modelRoot: modelRoot)
        case "nemotron":
            result = try await transcribeNemotron(audio: audio, language: language, modelRoot: modelRoot)
        default:
            result = try await transcribeWhisper(audio: audio, language: language, modelRoot: modelRoot)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let finished = ResourceSnapshot.now()
        guard
            result.segments.allSatisfy({
                $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start
            })
        else { throw ComparisonError("The provider returned invalid segment times.") }
        let report = ComparisonOutput(
            provider: provider,
            model: .init(
                id: result.modelID, revision: arguments["--model-revision"] ?? result.modelRevision,
                runtime: provider == "apple" ? "SpeechAnalyzer" : "Core ML"),
            language: language, segments: result.segments,
            timing: .init(
                modelLoadSeconds: result.modelLoadSeconds, audioDecodeSeconds: result.audioDecodeSeconds,
                transcriptionSeconds: result.transcriptionSeconds, totalSeconds: elapsed),
            resources: .init(
                cpuSeconds: finished.cpuSeconds - resources.cpuSeconds,
                peakRSSBytes: finished.peakRSSBytes,
                accountingScope: provider == "apple"
                    ? "Client process only; SpeechAnalyzer system-service CPU and memory are excluded."
                    : "Client process only; accelerator and external runtime-service resources are excluded."),
            timestampGranularity: result.timestampGranularity, diagnostics: result.diagnostics,
            timingScope: provider == "apple"
                ? "Model-load reports readiness checks and module creation; deferred system-service model loading and audio decoding are included in transcription."
                : (provider == "nemotron"
                    ? "Transcription includes audio decoding/resampling; audioDecodeSeconds is a measured subset."
                    : "Audio decoding is measured separately before transcription."),
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
}
