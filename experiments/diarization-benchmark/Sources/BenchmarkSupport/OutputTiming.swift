import Foundation

/// Wall times are relative to the replay clock, after model loading and input preparation.
/// Backlog is simulated audio that has arrived by completion but is not yet submitted.
public struct OutputTiming {
  private let paced: Bool
  private let totalAudioSeconds: Double
  private var updateID = 0
  private var inputLateness: [Double] = []
  private var outputLateness: [Double] = []
  private var backlog: [Double] = []

  public init(paced: Bool, totalAudioSeconds: Double) {
    self.paced = paced
    self.totalAudioSeconds = totalAudioSeconds
  }

  public var nextUpdateID: Int { updateID + 1 }

  public mutating func record(
    inputSeconds: Double, processingStarted: Double, completed: Double,
    outputAudioEnd: Double, finalFlush: Bool = false
  ) -> [String: Any] {
    updateID += 1
    var result: [String: Any] = [
      "phase": "output_timing", "update_id": updateID, "paced": paced,
      "input_available_audio_seconds": inputSeconds,
      "processing_started_seconds": processingStarted, "output_available_seconds": completed,
      "output_audio_end_seconds": outputAudioEnd, "final_flush": finalFlush,
      "scheduled_arrival_seconds": NSNull(), "input_lateness_seconds": NSNull(),
      "output_lateness_seconds": NSNull(), "backlog_seconds": NSNull(),
      "stable_identity": false,
    ]
    if paced {
      let inputDelay = max(0, processingStarted - inputSeconds)
      let outputDelay = max(0, completed - inputSeconds)
      let queued = max(0, min(totalAudioSeconds, completed) - inputSeconds)
      result["scheduled_arrival_seconds"] = inputSeconds
      result["input_lateness_seconds"] = inputDelay
      result["output_lateness_seconds"] = outputDelay
      result["backlog_seconds"] = queued
      if !finalFlush {
        inputLateness.append(inputDelay)
        outputLateness.append(outputDelay)
        backlog.append(queued)
      }
    }
    return result
  }

  public var summary: [String: Any] {
    var values: [String: Any] = ["live_timing_samples": outputLateness.count]
    for (name, samples) in [
      ("input_lateness", inputLateness), ("output_lateness", outputLateness), ("backlog", backlog),
    ] {
      if samples.isEmpty {
        values[name + "_max_ms"] = NSNull()
        values[name + "_p95_ms"] = NSNull()
      } else {
        let sorted = samples.sorted()
        values[name + "_max_ms"] = sorted.last! * 1000
        values[name + "_p95_ms"] = sorted[Int(Double(sorted.count - 1) * 0.95)] * 1000
      }
    }
    return values
  }
}
