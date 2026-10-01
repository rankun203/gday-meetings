import BenchmarkSupport
import CoreML
import Darwin
import FluidAudio
import Foundation

private let modelRevision = "df2625ac79a7ac6b65ad868fee6d80f320da4232"
private func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
private func peakRSS() -> Int64 {
  var usage = rusage()
  getrusage(RUSAGE_SELF, &usage)
  return Int64(usage.ru_maxrss)
}
private func emit(_ object: [String: Any]) throws {
  FileHandle.standardOutput.write(
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) + Data([10]))
}
private enum Failure: Error { case invalidInput(String) }

@main
struct Community1Benchmark {
  static func main() async {
    do { try await execute() } catch {
      try? emit(["phase": "error", "message": String(describing: error)])
      FileHandle.standardError.write(Data("Benchmark failed: \(error)\n".utf8))
      exit(1)
    }
  }

  private static func execute() async throws {
    guard CommandLine.arguments.count >= 2 else {
      throw Failure.invalidInput(
        "Usage: Community1Benchmark model-directory [generated-speech.wav]")
    }
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    let fileOptions: FileOptions?
    if arguments.contains("--audio") {
      fileOptions = try FileOptions(arguments: arguments)
    } else {
      guard arguments.isEmpty || (arguments.count == 1 && !arguments[0].hasPrefix("-")) else {
        throw Failure.invalidInput("Expected one fixture path or file options containing --audio")
      }
      fileOptions = nil
    }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let manifest =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as? [String: Any]
    guard manifest?["revision"] as? String == modelRevision else {
      throw Failure.invalidInput("Model manifest does not match the pinned snapshot")
    }
    AppLogger.minimumLevel = .warning
    let loadStart = now()
    // Construct local models directly: the convenience loader can download missing files.
    func load(_ name: String, _ units: MLComputeUnits) throws -> MLModel {
      let configuration = MLModelConfiguration()
      configuration.computeUnits = units
      return try MLModel(
        contentsOf: directory.appendingPathComponent(name + ".mlmodelc"),
        configuration: configuration)
    }
    let segmentation = try load("Segmentation", .all)
    let fbank = try load("FBank", .cpuOnly)
    let embedding = try load("Embedding", .all)
    let plda = try load("PldaRho", .all)
    let parameters =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: directory.appendingPathComponent("plda-parameters.json")))
      as? [String: Any]
    guard let tensors = parameters?["tensors"] as? [String: Any],
      let psi = tensors["psi"] as? [String: Any],
      let base64 = psi["data_base64"] as? String,
      let bytes = Data(base64Encoded: base64), !bytes.isEmpty, bytes.count % 4 == 0
    else { throw Failure.invalidInput("Invalid PLDA parameters") }
    var floats = [Float](repeating: 0, count: bytes.count / 4)
    _ = floats.withUnsafeMutableBytes { bytes.copyBytes(to: $0) }
    let models = OfflineDiarizerModels(
      segmentationModel: segmentation, fbankModel: fbank,
      embeddingModel: embedding, pldaRhoModel: plda, pldaPsi: floats.map(Double.init),
      compilationDuration: now() - loadStart)
    let manager = OfflineDiarizerManager()
    manager.initialize(models: models)
    try emit([
      "phase": "load", "seconds": now() - loadStart, "peak_rss_bytes": peakRSS(),
      "model_revision": modelRevision,
      "package_revision": "21493f8dac5a97e65742e6ff26f42f164c2fda0f",
      "compute_units": "all; FBank cpuOnly", "mode": "offline",
      "rust_text_processing_linked": TextNormalizer.shared.isNativeAvailable,
      "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
    ])
    if let fileOptions {
      try await runFile(manager, options: fileOptions)
    } else if CommandLine.arguments.count == 3 {
      let audio = try AudioConverter().resampleAudioFile(
        URL(fileURLWithPath: CommandLine.arguments[2]))
      guard !audio.isEmpty, audio.count <= 16000 * 120 else {
        throw Failure.invalidInput("Fixture must contain at most 120 seconds")
      }
      try await run(manager, samples: audio, phase: "speech_warmup")
      try await run(manager, samples: audio, phase: "generated_speech")
    } else {
      try await run(
        manager, samples: [Float](repeating: 0, count: 16000 * 5), phase: "warmup_silence")
      try await run(
        manager, samples: [Float](repeating: 0, count: 16000 * 60), phase: "silence_60s")
      try await run(
        manager, samples: [Float](repeating: 0, count: 16000 * 300), phase: "silence_300s")
    }
  }

  private struct SliceSource: AudioSampleSource {
    let base: any AudioSampleSource
    let start: Int
    let sampleCount: Int
    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws
    {
      try base.copySamples(
        into: destination, offset: start + offset, count: min(count, sampleCount - offset))
    }
  }

  private static func runFile(_ manager: OfflineDiarizerManager, options: FileOptions) async throws
  {
    let path = options.audio
    let mode = options.mode
    let paced = options.paced
    let maxSeconds = options.maxSeconds ?? .infinity
    let offset = options.offsetSeconds
    let wallLimit = options.wallLimitSeconds
    let (source, loading) = try AudioSourceFactory().makeDiskBackedSource(
      from: URL(fileURLWithPath: path), targetSampleRate: 16000)
    defer { source.cleanup() }
    let first = min(source.sampleCount, Int(offset * 16000))
    let count =
      maxSeconds.isFinite
      ? min(source.sampleCount - first, Int(maxSeconds * 16000)) : source.sampleCount - first
    guard count > 0 else { throw Failure.invalidInput("Input is empty") }
    let segmentURL = options.segmentsOutput.map { URL(fileURLWithPath: $0) }
    if let segmentURL { try Data().write(to: segmentURL) }
    let start = now()
    if mode == "offline" {
      _ = try await runSource(
        manager, source: SliceSource(base: source, start: first, sampleCount: count),
        phase: "file_offline", loading: loading, endSeconds: offset + Double(count) / 16000,
        segmentURL: segmentURL, windowStart: offset)
      return
    }
    // Recompute each trailing 30-second window every 10 seconds. Speaker IDs are
    // local to each offline result; this adapter makes no cross-window identity claim.
    var end = 0
    var updates = 0
    var nextUpdate = min(160000, count)
    var firstResult = -1.0
    var outputTiming = OutputTiming(paced: paced, totalAudioSeconds: Double(count) / 16000)
    while end < count {
      end = min(end + 320, count)
      if paced {
        let wait = start + Double(end) / 16000 - now()
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
      }
      if end < nextUpdate { continue }
      nextUpdate = min(end + 160000, count)
      let begin = max(0, end - 480000)
      let processingStarted = now() - start
      let completed = try await runSource(
        manager, source: SliceSource(base: source, start: first + begin, sampleCount: end - begin),
        phase: "replay_window", loading: 0, endSeconds: offset + Double(end) / 16000,
        segmentURL: segmentURL,
        windowStart: offset + Double(begin) / 16000, updateID: outputTiming.nextUpdateID,
        replayStart: start)
      try emit(
        outputTiming.record(
          inputSeconds: Double(end) / 16000,
          processingStarted: processingStarted, completed: completed,
          outputAudioEnd: offset + Double(end) / 16000))
      if firstResult < 0 { firstResult = completed }
      updates += 1
      if now() - start > wallLimit { throw Failure.invalidInput("Run stopped at wall-time limit") }
    }
    var report: [String: Any] = [
      "phase": "replay_summary", "mode": "windowed_offline_recomputation", "paced": paced,
      "audio_seconds": Double(count) / 16000, "wall_seconds": now() - start,
      "first_result_wall_seconds": firstResult, "updates": updates,
      "first_output_kind": "recomputed_window_not_stable_identity",
      "window_seconds": 30, "update_seconds": 10, "speaker_ids_persist_across_windows": false,
      "peak_rss_bytes": peakRSS(),
    ]
    report.merge(outputTiming.summary) { _, value in value }
    try emit(report)
  }

  private static func runSource(
    _ manager: OfflineDiarizerManager, source: any AudioSampleSource, phase: String,
    loading: Double, endSeconds: Double = 0, segmentURL: URL? = nil, windowStart: Double = 0,
    updateID: Int = 0, replayStart: Double? = nil
  ) async throws -> Double {
    let start = now()
    let prepared = try await manager.prepare(audioSource: source, audioLoadingSeconds: loading)
    let prepareSeconds = now() - start
    var status = "completed"
    var segments = 0
    var speakers = 0
    var outputAvailable = 0.0
    do {
      let result = try manager.cluster(prepared)
      segments = result.segments.count
      speakers = Set(result.segments.map(\.speakerId)).count
      guard
        result.segments.allSatisfy({
          $0.startTimeSeconds.isFinite && $0.endTimeSeconds.isFinite && $0.startTimeSeconds >= 0
            && $0.endTimeSeconds >= $0.startTimeSeconds
        })
      else { throw Failure.invalidInput("Invalid segment timestamps") }
      outputAvailable = now() - (replayStart ?? start)
      if let segmentURL {
        let handle = try FileHandle(forWritingTo: segmentURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        for segment in result.segments {
          let value: [String: Any] = [
            "speaker": segment.speakerId,
            "start_seconds": windowStart + Double(segment.startTimeSeconds),
            "end_seconds": min(
              windowStart + Double(segment.endTimeSeconds),
              windowStart + Double(source.sampleCount) / 16000),
            "window_end_seconds": endSeconds, "window_start_seconds": windowStart,
            "provisional": phase == "replay_window",
            "update_id": updateID, "output_available_seconds": outputAvailable,
          ]
          try handle.write(
            contentsOf: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
              + Data([10]))
        }
      }
    } catch OfflineDiarizationError.noSpeechDetected {
      status = "no_speech_detected"
      outputAvailable = now() - (replayStart ?? start)
    }
    let wall = now() - start
    try emit([
      "phase": phase, "status": status, "audio_seconds": Double(source.sampleCount) / 16000,
      "wall_seconds": wall, "preparation_seconds": prepareSeconds, "audio_loading_seconds": loading,
      "audio_seconds_per_wall_second": Double(source.sampleCount) / 16000 / wall,
      "segmentation_chunks": prepared.segmentationChunkCount, "embeddings": prepared.embeddingCount,
      "segments": segments, "speakers": speakers, "window_end_seconds": endSeconds,
      "peak_rss_bytes": peakRSS(), "streaming": false,
      "update_id": updateID, "output_available_seconds": outputAvailable,
      "window_start_seconds": windowStart,
    ])
    guard peakRSS() <= 2_147_483_648 else { throw Failure.invalidInput("Stopped at memory limit") }
    return outputAvailable
  }

  private static func run(_ manager: OfflineDiarizerManager, samples: [Float], phase: String)
    async throws
  {
    let start = now()
    let prepared = try await manager.prepare(audioSource: ArrayAudioSampleSource(samples: samples))
    let preparationSeconds = now() - start
    var status = "completed"
    var segments = 0
    var speakers = 0
    do {
      let result = try manager.cluster(prepared)
      segments = result.segments.count
      speakers = Set(result.segments.map(\.speakerId)).count
      guard
        result.segments.allSatisfy({
          $0.startTimeSeconds.isFinite && $0.endTimeSeconds.isFinite && $0.startTimeSeconds >= 0
            && $0.endTimeSeconds >= $0.startTimeSeconds
        })
      else { throw Failure.invalidInput("Invalid segment timestamps") }
    } catch OfflineDiarizationError.noSpeechDetected {
      status = "no_speech_detected"
    }
    let wall = now() - start
    try emit([
      "phase": phase, "status": status, "audio_seconds": Double(samples.count) / 16000,
      "wall_seconds": wall, "preparation_seconds": preparationSeconds,
      "audio_seconds_per_wall_second": Double(samples.count) / 16000 / wall,
      "segmentation_chunks": prepared.segmentationChunkCount, "embeddings": prepared.embeddingCount,
      "segments": segments, "speakers": speakers, "peak_rss_bytes": peakRSS(),
      "streaming": false,
    ])
    guard peakRSS() <= 2_147_483_648 else {
      throw Failure.invalidInput("Stopped at the memory limit")
    }
  }
}
