import AVFoundation
import CoreMedia
import Foundation
import Speech

/// Mirrors the app's recorded SpeechAnalyzer path using pull-based file input.
func transcribeApple(audio: URL, language: String, modelRoot: URL) async throws -> AdapterResult {
    let loading = ProcessInfo.processInfo.systemUptime
    guard SpeechTranscriber.isAvailable else { throw ComparisonError("SpeechTranscriber is unavailable on this Mac.") }
    let supported = await SpeechTranscriber.supportedLocales
    let requested = Locale(identifier: language)
    guard
        let locale = supported.first(where: {
            $0.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
                == requested.identifier.replacingOccurrences(of: "_", with: "-").lowercased()
        })
    else { throw ComparisonError("The requested speech language is unsupported.") }
    let transcriber = SpeechTranscriber(
        locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    guard await AssetInventory.status(forModules: [transcriber]) == .installed else {
        throw ComparisonError(
            "Prepare the Apple speech model before timed transcription; automatic downloads are disabled.")
    }
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    let modelLoaded = ProcessInfo.processInfo.systemUptime
    let results = Task { () throws -> [OutputSegment] in
        var segments: [OutputSegment] = []
        for try await result in transcriber.results where result.isFinal {
            segments.append(
                .init(
                    start: result.range.start.seconds, end: CMTimeRangeGetEnd(result.range).seconds,
                    text: String(result.text.characters)))
        }
        return segments
    }
    let transcriptionStart = ProcessInfo.processInfo.systemUptime
    do {
        let file = try AVAudioFile(forReading: audio)
        let end = try await analyzer.analyzeSequence(from: file)
        if let end {
            try await analyzer.finalizeAndFinish(through: end)
        }
        else {
            await analyzer.cancelAndFinishNow()
        }
        let segments = try await results.value
        return .init(
            segments: segments, modelID: "Apple SpeechTranscriber/\(locale.identifier)",
            modelRevision: ProcessInfo.processInfo.operatingSystemVersionString,
            modelLoadSeconds: modelLoaded - loading,
            transcriptionSeconds: ProcessInfo.processInfo.systemUptime - transcriptionStart)
    }
    catch {
        results.cancel()
        await analyzer.cancelAndFinishNow()
        _ = try? await results.value
        throw error
    }
}

struct AppleAssetPreparation: Encodable {
    var locale: String
    var previousStatus: String
    var finalStatus: String
    var downloadRequested: Bool
    var setupSeconds: Double
}

/// Explicit experiment setup, kept outside timed transcription invocations.
func prepareAppleAssets(language: String) async throws -> AppleAssetPreparation {
    let started = ProcessInfo.processInfo.systemUptime
    guard SpeechTranscriber.isAvailable else { throw ComparisonError("SpeechTranscriber is unavailable on this Mac.") }
    let expected = language.replacingOccurrences(of: "_", with: "-").lowercased()
    guard
        let locale = await SpeechTranscriber.supportedLocales.first(where: {
            $0.identifier.replacingOccurrences(of: "_", with: "-").lowercased() == expected
        })
    else { throw ComparisonError("The requested Apple speech language is unsupported.") }
    let module = SpeechTranscriber(
        locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
    let previous = await AssetInventory.status(forModules: [module])
    guard previous != .unsupported else {
        throw ComparisonError("Apple speech assets are unsupported for this language.")
    }
    var requested = false
    if previous != .installed {
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(locale) {
            guard reserved.count < AssetInventory.maximumReservedLocales else {
                throw ComparisonError(
                    "Apple speech locale reservations are full. Existing reservations were preserved.")
            }
            _ = try await AssetInventory.reserve(locale: locale)
        }
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
            requested = true
            try await request.downloadAndInstall()
        }
    }
    let final = await AssetInventory.status(forModules: [module])
    guard final == .installed else { throw ComparisonError("Apple speech assets did not finish installing.") }
    return .init(
        locale: locale.identifier, previousStatus: String(describing: previous), finalStatus: String(describing: final),
        downloadRequested: requested, setupSeconds: ProcessInfo.processInfo.systemUptime - started)
}
