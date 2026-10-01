import AVFoundation
import BenchmarkSupport
import CoreML
import Darwin
import FluidAudio
import Foundation

private let packageRevision = "21493f8dac5a97e65742e6ff26f42f164c2fda0f"
private let modelRevision = "25a90f97f254428d4b30374b76af9c74fdee8327"

private func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }
private func peakRSS() -> Int64 {
  var usage = rusage()
  getrusage(RUSAGE_SELF, &usage)
  return Int64(usage.ru_maxrss)
}
private func log(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}
private func emit(_ object: [String: Any]) throws {
  let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
  FileHandle.standardOutput.write(data + Data([10]))
}
private func percentile(_ values: [Double], _ fraction: Double) -> Double {
  let sorted = values.sorted()
  return sorted.isEmpty
    ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * fraction))]
}
private enum Failure: Error {
  case invalidArguments
  case invalidOutput(String)
}

@main
struct Benchmark {
  static func main() async {
    do { try await execute() } catch {
      try? emit(["phase": "error", "message": String(describing: error)])
      log("Benchmark failed: \(error)")
      exit(1)
    }
  }

  private static func execute() async throws {
    guard CommandLine.arguments.count >= 2 else {
      log("Usage: NemotronBenchmark model-directory [generated-speech.wav]")
      throw Failure.invalidArguments
    }
    let arguments = Array(CommandLine.arguments.dropFirst(2))
    if arguments.contains("--audio") {
      try await runFile(
        try FileOptions(arguments: arguments),
        modelDirectory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
      )
      return
    }
    guard arguments.isEmpty || (arguments.count == 1 && !arguments[0].hasPrefix("-")) else {
      throw Failure.invalidArguments
    }
    let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    let manifest =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: directory.appendingPathComponent("manifest.json"))) as? [String: Any]
    guard manifest?["revision"] as? String == modelRevision else {
      throw Failure.invalidOutput("Model manifest does not match the pinned snapshot")
    }
    AppLogger.minimumLevel = .warning
    AppLogger.mirrorsToConsole = true
    let loadStart = now()
    let models = try await Nemotron3Models.load(
      config: .low, directory: directory, computeUnits: .all)
    try emit([
      "phase": "load", "seconds": now() - loadStart, "peak_rss_bytes": peakRSS(),
      "package_revision": packageRevision, "model_revision": modelRevision,
      "os": ProcessInfo.processInfo.operatingSystemVersionString,
      "compute_units": "all", "preset": "low",
      "rust_text_processing_linked": TextNormalizer.shared.isNativeAvailable,
      "input": CommandLine.arguments.count == 3
        ? "generated_speech_16000_hz_mono" : "generated_silence_16000_hz_mono",
      "processor_count": ProcessInfo.processInfo.processorCount,
      "physical_memory_bytes": ProcessInfo.processInfo.physicalMemory,
      "unpaced_wall_limit_seconds": 180, "peak_rss_limit_bytes": 2_147_483_648,
    ])
    let diarizer = Nemotron3Diarizer(config: .low, models: models)
    if CommandLine.arguments.count == 3 {
      let audio = try AudioConverter().resampleAudioFile(
        URL(fileURLWithPath: CommandLine.arguments[2]))
      guard !audio.isEmpty, audio.count <= 16000 * 120 else { throw Failure.invalidArguments }
      try await run(diarizer, seconds: 0, paced: false, phase: "speech_warmup", audio: audio)
      try await run(diarizer, seconds: 0, paced: false, phase: "generated_speech", audio: audio)
      return
    }
    try await run(diarizer, seconds: 5, paced: false, phase: "warmup")
    try await run(diarizer, seconds: 60, paced: true, phase: "paced")
    try await run(diarizer, seconds: 3600, paced: false, phase: "unpaced")
  }

  private static func runFile(_ options: FileOptions, modelDirectory: URL) async throws {
    let path = options.audio
    let mode = options.mode
    let paced = options.paced
    let maxSeconds = options.maxSeconds ?? .infinity
    let offset = options.offsetSeconds
    let wallLimit = options.wallLimitSeconds
    let manifest =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: modelDirectory.appendingPathComponent("manifest.json")))
      as? [String: Any]
    guard manifest?["revision"] as? String == modelRevision else { throw Failure.invalidArguments }
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
      file.processingFormat.commonFormat == .pcmFormatFloat32
    else { throw Failure.invalidOutput("Input must be prepared as 16 kHz mono PCM") }
    file.framePosition = min(file.length, AVAudioFramePosition(offset * 16000))
    let available = file.length - file.framePosition
    let requested =
      maxSeconds.isFinite ? min(available, AVAudioFramePosition(maxSeconds * 16000)) : available
    guard requested > 0,
      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 320)
    else { throw Failure.invalidArguments }
    AppLogger.minimumLevel = .warning
    let loadStart = now()
    let models = try await Nemotron3Models.load(
      config: .low, directory: modelDirectory, computeUnits: .all)
    try emit([
      "phase": "load", "seconds": now() - loadStart, "peak_rss_bytes": peakRSS(),
      "package_revision": packageRevision, "model_revision": modelRevision, "preset": "low",
      "compute_units": "all",
      "rust_text_processing_linked": TextNormalizer.shared.isNativeAvailable, "mode": mode,
      "processing": "native_streaming_20ms", "paced": paced,
    ])
    let diarizer = Nemotron3Diarizer(config: .low, models: models)
    var received: Int64 = 0
    var frames = 0
    var chunks = 0
    var activeFrames = [Int](repeating: 0, count: 8)
    var activeStarts = [Double?](repeating: nil, count: 8)
    let segmentHandle: FileHandle?
    if let output = options.segmentsOutput {
      FileManager.default.createFile(atPath: output, contents: nil)
      segmentHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: output))
      try segmentHandle?.truncate(atOffset: 0)
    } else {
      segmentHandle = nil
    }
    defer { try? segmentHandle?.close() }
    func segment(_ speaker: Int, _ begin: Double, _ end: Double) throws {
      guard end > begin, let segmentHandle else { return }
      let value: [String: Any] = [
        "speaker": "slot-\(speaker)", "start_seconds": offset + begin,
        "end_seconds": offset + end, "threshold": 0.5, "provisional": true,
      ]
      try segmentHandle.write(
        contentsOf: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
          + Data([10]))
    }
    var firstInput = -1.0
    var firstResult = -1.0
    var timings: [Double] = []
    var stopReason = "completed"
    let start = now()
    var outputTiming = OutputTiming(paced: paced, totalAudioSeconds: Double(requested) / 16000)
    var timedFrames = 0
    func reportTiming(
      _ results: [Nemotron3ChunkResult], started: Double, completed: Double, final: Bool = false
    ) throws {
      for result in results {
        timedFrames += result.frameCount
        try emit(
          outputTiming.record(
            inputSeconds: Double(received) / 16000, processingStarted: started,
            completed: completed,
            outputAudioEnd: offset + min(Double(timedFrames) * 0.01, Double(received) / 16000),
            finalFlush: final))
      }
    }
    func consume(_ results: [Nemotron3ChunkResult]) throws {
      for result in results {
        guard result.numSpeakers == 8, result.probabilities.count == result.frameCount * 8,
          result.probabilities.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 })
        else { throw Failure.invalidOutput("Invalid probabilities") }
        for frame in 0..<result.frameCount {
          let time = min(Double(frames + frame) * 0.01, Double(received) / 16000)
          for speaker in 0..<8 {
            let active = result.probabilities[frame * 8 + speaker] >= 0.5
            if active {
              activeFrames[speaker] += 1
              if activeStarts[speaker] == nil { activeStarts[speaker] = time }
            } else if let begin = activeStarts[speaker] {
              try segment(speaker, begin, time)
              activeStarts[speaker] = nil
            }
          }
        }
        frames += result.frameCount
        chunks += 1
      }
    }
    while received < requested {
      try file.read(into: buffer, frameCount: AVAudioFrameCount(min(320, requested - received)))
      guard buffer.frameLength > 0, let samples = buffer.floatChannelData?[0] else {
        throw Failure.invalidOutput("Unexpected end of input")
      }
      received += Int64(buffer.frameLength)
      if paced {
        let wait = start + Double(received) / 16000 - now()
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
      }
      let callStart = now()
      let results = try autoreleasepool {
        diarizer.appendAudio(
          Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))))
        return try diarizer.processBufferedAudio()
      }
      let completed = now() - start
      if !results.isEmpty {
        timings.append(now() - callStart)
        if firstInput < 0 {
          firstInput = Double(received) / 16000
          firstResult = now() - start
        }
      }
      try consume(results)
      try reportTiming(results, started: callStart - start, completed: completed)
      if peakRSS() > 2_147_483_648 {
        stopReason = "peak_rss_limit"
        break
      }
      if now() - start > wallLimit {
        stopReason = "wall_time_limit"
        break
      }
    }
    let beforeFinish = frames
    let finishStart = now()
    let tail = try diarizer.finishStream()
    let finishCompleted = now() - start
    try consume(tail)
    try reportTiming(tail, started: finishStart - start, completed: finishCompleted, final: true)
    let finishSeconds = now() - finishStart
    guard try diarizer.finishStream().isEmpty else {
      throw Failure.invalidOutput("Finish is not idempotent")
    }
    for speaker in 0..<8 {
      if let begin = activeStarts[speaker] { try segment(speaker, begin, Double(received) / 16000) }
    }
    let expected = 1 + (Int(received) + 112) / 160
    guard frames == expected else { throw Failure.invalidOutput("Centered frame count mismatch") }
    let wall = now() - start
    var report: [String: Any] = [
      "phase": "file", "mode": mode, "paced": paced, "processing": "native_streaming_20ms",
      "requested_audio_seconds": Double(requested) / 16000,
      "audio_seconds": Double(received) / 16000,
      "wall_seconds": wall, "audio_seconds_per_wall_second": Double(received) / 16000 / wall,
      "frames": frames, "expected_centered_frames": expected, "frames_before_finish": beforeFinish,
      "frame_grid_span_seconds": Double(frames - 1) * 0.01,
      "frame_bin_duration_seconds": Double(frames) * 0.01,
      "first_result_input_seconds": firstInput, "first_result_wall_seconds": firstResult,
      "first_output_kind": "probability_chunk_not_stable_label",
      "finish_seconds": finishSeconds, "chunks": chunks, "stop_reason": stopReason,
      "inference_call_p50_ms": percentile(timings, 0.5) * 1000,
      "inference_call_p95_ms": percentile(timings, 0.95) * 1000,
      "speaker_active_seconds_at_threshold_0_5": activeFrames.map { Double($0) * 0.01 },
      "speaker_slots_with_at_least_0_5_seconds": activeFrames.filter { $0 >= 50 }.count,
      "peak_rss_bytes": peakRSS(),
    ]
    report.merge(outputTiming.summary) { _, value in value }
    try emit(report)
    if stopReason != "completed" { throw Failure.invalidOutput("Run stopped at a resource limit") }
  }

  private static func run(
    _ diarizer: Nemotron3Diarizer, seconds: Int, paced: Bool, phase: String, audio: [Float]? = nil
  ) async throws {
    diarizer.reset()
    let block = [Float](repeating: 0, count: 320)
    let start = now()
    let rssStart = peakRSS()
    var firstResult: Double?
    var firstInputSeconds: Double?
    var frames = 0
    var chunks = 0
    var calls: [Double] = []
    var inferenceCalls: [Double] = []
    var maxLateness = 0.0
    var memory: [[String: Any]] = []
    var samplesProcessed = 0
    let requestedSamples = audio?.count ?? seconds * 16000
    var stopReason = "completed"
    func consume(_ results: [Nemotron3ChunkResult]) throws {
      for result in results {
        guard result.numSpeakers == 8,
          result.probabilities.count == result.frameCount * result.numSpeakers,
          result.probabilities.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 })
        else { throw Failure.invalidOutput("Invalid speaker probability output") }
        frames += result.frameCount
        chunks += 1
      }
    }
    log("Starting \(phase): \(Double(requestedSamples) / 16000) audio seconds")
    for index in 0..<((requestedSamples + 319) / 320) {
      let endSample = min((index + 1) * 320, requestedSamples)
      let audioSeconds = Double(endSample) / 16000
      let input = audio.map { Array($0[(index * 320)..<endSample]) } ?? block
      if paced {
        let wait = start + audioSeconds - now()
        if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
        maxLateness = max(maxLateness, now() - start - audioSeconds)
      }
      let callStart = now()
      let results = try autoreleasepool {
        diarizer.appendAudio(input)
        return try diarizer.processBufferedAudio()
      }
      let elapsed = now() - callStart
      calls.append(elapsed)
      if !results.isEmpty {
        inferenceCalls.append(elapsed)
        if firstResult == nil {
          firstResult = now() - start
          firstInputSeconds = audioSeconds
        }
      }
      try consume(results)
      samplesProcessed = endSample
      if peakRSS() > 2_147_483_648 {
        stopReason = "peak_rss_limit"
        break
      }
      if phase == "unpaced", now() - start > 180 {
        stopReason = "wall_time_limit"
        break
      }
      if (index + 1) % 3000 == 0 {
        memory.append(["audio_seconds": audioSeconds, "peak_rss_bytes": peakRSS()])
        if (index + 1) % 15000 == 0 {
          log("\(phase): processed \(Int(audioSeconds)) audio seconds")
        }
      }
    }
    let framesBeforeFinish = frames
    let finishStart = now()
    try consume(diarizer.finishStream())
    let finishSeconds = now() - finishStart
    guard try diarizer.finishStream().isEmpty else {
      throw Failure.invalidOutput("Finish is not idempotent")
    }
    // Pinned frontend: 1 + (N + 2*(512/2) - 400) / 160 centered mel frames.
    let expectedFrames = samplesProcessed > 0 ? 1 + (samplesProcessed + 112) / 160 : 0
    guard frames == expectedFrames else {
      throw Failure.invalidOutput("Expected \(expectedFrames) centered frames, received \(frames)")
    }
    let wall = now() - start
    try emit([
      "phase": phase, "requested_audio_seconds": Double(requestedSamples) / 16000,
      "audio_seconds": Double(samplesProcessed) / 16000, "stop_reason": stopReason,
      "wall_seconds": wall,
      "audio_seconds_per_wall_second": Double(samplesProcessed) / 16000 / wall,
      "first_result_wall_seconds": firstResult ?? -1,
      "first_result_input_seconds": firstInputSeconds ?? -1,
      "frames": frames, "expected_centered_frames": expectedFrames,
      "frame_grid_span_seconds": Double(max(0, frames - 1)) * 0.01,
      "frame_bin_duration_seconds": Double(frames) * 0.01,
      "frame_bin_excess_seconds": Double(frames) * 0.01 - Double(samplesProcessed) / 16000,
      "frames_before_finish": framesBeforeFinish, "chunks": chunks,
      "finish_seconds": finishSeconds, "calls": calls.count,
      "all_call_p50_ms": percentile(calls, 0.5) * 1000,
      "all_call_p95_ms": percentile(calls, 0.95) * 1000,
      "inference_call_p50_ms": percentile(inferenceCalls, 0.5) * 1000,
      "inference_call_p95_ms": percentile(inferenceCalls, 0.95) * 1000,
      "max_pacing_lateness_ms": maxLateness * 1000,
      "peak_rss_at_start_bytes": rssStart, "peak_rss_bytes": peakRSS(),
      "memory_samples": memory,
    ])
    log("Finished \(phase): \(frames) frames in \(wall) seconds (\(stopReason))")
    if stopReason == "peak_rss_limit" { throw Failure.invalidOutput("Stopped at the memory limit") }
  }
}
