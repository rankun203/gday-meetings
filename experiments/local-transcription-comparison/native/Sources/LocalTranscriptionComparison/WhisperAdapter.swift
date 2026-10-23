import Foundation
import WhisperKit

/// Uses the pinned Swift/Core ML runtime and prepared local assets.
/// Tokenizer preflight rejects invalid local inputs before WhisperKit's local-first loader.
func transcribeWhisper(audio: URL, language: String, modelRoot: URL) async throws -> AdapterResult {
    let loading = ProcessInfo.processInfo.systemUptime
    let files = FileManager.default
    for component in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
        let compiled = modelRoot.appendingPathComponent(component + ".mlmodelc")
        let package = modelRoot.appendingPathComponent(component + ".mlpackage")
        guard files.fileExists(atPath: compiled.path) || files.fileExists(atPath: package.path) else {
            throw ComparisonError("Prepare the local Whisper \(component) model before transcribing.")
        }
    }
    for file in ["tokenizer.json", "tokenizer_config.json"] {
        guard files.fileExists(atPath: modelRoot.appendingPathComponent(file).path) else {
            throw ComparisonError("Prepare \(file) in the local Whisper model folder before transcribing.")
        }
    }
    // The direct-folder factory reads local configuration; it has no Hub fallback.
    // Keep the fixture immutable through loading, since WhisperKit's own tokenizer
    // factory can download a fallback if those same local files change or fail.
    let localTokenizer = try await AutoTokenizerWrapper.from(modelFolder: modelRoot)
    let normalizedLanguage = language.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "_", with: "-").lowercased()
    let code =
        normalizedLanguage.isEmpty || normalizedLanguage == "auto"
        ? nil : normalizedLanguage.split(separator: "-").first.map(String.init)
    if let code {
        let token = "<|\(code)|>"
        guard let tokenID = localTokenizer.convertTokenToId(token),
            localTokenizer.convertIdToToken(tokenID) == token
        else { throw ComparisonError("This Whisper model doesn't support the requested language.") }
    }
    try Task.checkCancellation()
    let engine = try await WhisperKit(
        WhisperKitConfig(
            modelFolder: modelRoot.path, tokenizerFolder: modelRoot,
            verbose: false, prewarm: false, load: true, download: false))
    let modelLoaded = ProcessInfo.processInfo.systemUptime
    do {
        try Task.checkCancellation()
        let decoding = ProcessInfo.processInfo.systemUptime
        let samples = try AudioProcessor.loadAudioAsFloatArray(fromPath: audio.path)
        let decodeSeconds = ProcessInfo.processInfo.systemUptime - decoding
        guard !samples.isEmpty else { throw ComparisonError("The recording contains no audio samples.") }
        let duration = Double(samples.count) / Double(WhisperKit.sampleRate)
        let options = DecodingOptions(
            verbose: false, task: .transcribe, language: code, detectLanguage: code == nil,
            skipSpecialTokens: true, withoutTimestamps: false, wordTimestamps: false,
            concurrentWorkerCount: 1)
        let started = ProcessInfo.processInfo.systemUptime
        let results = try await engine.transcribe(audioArray: samples, decodeOptions: options)
        let transcriptionSeconds = ProcessInfo.processInfo.systemUptime - started
        try Task.checkCancellation()
        var segments: [OutputSegment] = []
        for segment in results.flatMap(\.segments) {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let start = Double(segment.start)
            let rawEnd = Double(segment.end)
            let end = min(duration, rawEnd)
            guard start.isFinite, rawEnd.isFinite, start >= 0, end > start else {
                throw ComparisonError("Whisper returned an invalid timed segment.")
            }
            segments.append(.init(start: start, end: end, text: text))
        }
        await engine.unloadModels()
        return .init(
            segments: segments,
            modelID: "argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_626MB",
            modelRevision: "0f63a7800b00dd0226abd051b906c246e1907482",
            modelLoadSeconds: modelLoaded - loading,
            transcriptionSeconds: transcriptionSeconds,
            audioDecodeSeconds: decodeSeconds,
            timestampGranularity: "segment")
    }
    catch {
        await engine.unloadModels()
        throw error
    }
}
