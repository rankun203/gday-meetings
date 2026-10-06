import AVFoundation
import Foundation
import Speech

// Offline file replay through the app's live-transcription preset. This harness
// does not open capture devices or modify the library. It retains speech assets
// using the same reservation API as the app and never releases app reservations.
@main struct AppleTranscribe {
  static func main() async {
    do { try await run() } catch {
      FileHandle.standardError.write(Data("\(error)\n".utf8))
      exit(1)
    }
  }
  static func run() async throws {
    let args = CommandLine.arguments
    if args.count == 2 && args[1] == "--probe" {
      let receipt: [String: Any] = [
        "available": SpeechTranscriber.isAvailable,
        "installed": await SpeechTranscriber.installedLocales.map(\.identifier),
        "supported": await SpeechTranscriber.supportedLocales.map(\.identifier),
      ]
      print(String(data: try JSONSerialization.data(withJSONObject: receipt), encoding: .utf8)!)
      return
    }
    guard args.count == 5 else {
      throw NSError(domain: "Usage: apple-transcribe INPUT OUTPUT LOCALE REALTIME", code: 1)
    }
    let input = URL(fileURLWithPath: args[1])
    let output = URL(fileURLWithPath: args[2])
    guard
      let locale = await SpeechTranscriber.supportedLocale(
        equivalentTo: Locale(identifier: args[3]))
    else {
      throw NSError(domain: "Unsupported transcription locale", code: 2)
    }
    let realtime = args[4] == "true"
    _ = try await AssetInventory.reserve(locale: locale)
    let transcriber = SpeechTranscriber(
      locale: locale, preset: .timeIndexedProgressiveTranscription)
    guard SpeechTranscriber.isAvailable else {
      throw NSError(domain: "Speech unavailable", code: 2)
    }
    let readiness = await AssetInventory.status(forModules: [transcriber])
    if readiness != .installed {
      print("Preparing speech assets: \(readiness)")
      if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber])
      {
        try await request.downloadAndInstall()
      }
    }
    guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    else {
      throw NSError(domain: "No compatible audio format", code: 3)
    }
    let converted = output.deletingLastPathComponent().appendingPathComponent(
      UUID().uuidString + ".wav")
    defer { try? FileManager.default.removeItem(at: converted) }
    let conversion = Process()
    conversion.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
    conversion.arguments = [
      "-v", "error", "-i", input.path, "-ar", String(Int(format.sampleRate)),
      "-ac", String(format.channelCount), "-c:a", "pcm_s16le", converted.path,
    ]
    try conversion.run()
    conversion.waitUntilExit()
    guard conversion.terminationStatus == 0 else {
      throw NSError(domain: "Audio conversion failed", code: 4)
    }
    let file = try AVAudioFile(
      forReading: converted, commonFormat: format.commonFormat,
      interleaved: format.isInterleaved)
    let analyzer = SpeechAnalyzer(modules: [transcriber])
    try await analyzer.prepareToAnalyze(in: file.processingFormat)
    let started = ContinuousClock.now
    func elapsed() -> Double {
      let d = started.duration(to: .now).components
      return Double(d.seconds) + Double(d.attoseconds) / 1e18
    }
    let results = Task { () throws -> [[String: Any]] in
      var events: [[String: Any]] = []
      for try await result in transcriber.results {
        let words: [[String: Any]] = result.text.runs.compactMap { run in
          guard let time = run.audioTimeRange else { return nil }
          return [
            "text": String(result.text[run.range].characters), "start": time.start.seconds,
            "end": CMTimeRangeGetEnd(time).seconds,
          ]
        }
        events.append([
          "text": String(result.text.characters), "start": result.range.start.seconds,
          "end": CMTimeRangeGetEnd(result.range).seconds, "final": result.isFinal,
          "received_seconds": elapsed(), "words": words,
        ])
      }
      return events
    }
    let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
    try await analyzer.start(inputSequence: stream)
    let packetFrames = AVAudioFrameCount(file.processingFormat.sampleRate / 10)
    while file.framePosition < file.length {
      let position = file.framePosition
      let count = min(packetFrames, AVAudioFrameCount(file.length - position))
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count)!
      try file.read(into: buffer, frameCount: count)
      if realtime {
        let deadline =
          Double(position + Int64(buffer.frameLength)) / file.processingFormat.sampleRate
        let remaining = deadline - elapsed()
        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
      }
      continuation.yield(
        AnalyzerInput(
          buffer: buffer,
          bufferStartTime: CMTime(
            value: position, timescale: CMTimeScale(file.processingFormat.sampleRate))))
    }
    continuation.finish()
    try await analyzer.finalizeAndFinishThroughEndOfInput()
    let events = try await results.value
    let receipt: [String: Any] = [
      "engine": "Apple SpeechTranscriber", "locale": locale.identifier,
      "preset": "timeIndexedProgressiveTranscription", "realtime": realtime, "packet_seconds": 0.1,
      "os": ProcessInfo.processInfo.operatingSystemVersionString, "seconds": elapsed(),
      "duration_seconds": Double(file.length) / file.processingFormat.sampleRate, "events": events,
      "segments": events.filter { $0["final"] as? Bool == true },
    ]
    try JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys])
      .write(to: output, options: .atomic)
    print("Completed Apple transcription")
  }
}
