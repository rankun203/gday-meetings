import Foundation

public enum OptionError: Error {
  case invalidArgument(String)
}

public struct FileOptions: Sendable {
  public let audio: String
  public let mode: String
  public let paced: Bool
  public let maxSeconds: Double?
  public let offsetSeconds: Double
  public let wallLimitSeconds: Double
  public let segmentsOutput: String?

  public init(arguments: [String]) throws {
    var values: [String: String] = [:]
    var paced = false
    var index = 0
    let names = [
      "--audio", "--mode", "--max-seconds", "--offset-seconds", "--wall-limit-seconds",
      "--segments-output",
    ]
    while index < arguments.count {
      let name = arguments[index]
      if name == "--paced" {
        guard !paced else { throw OptionError.invalidArgument(name) }
        paced = true
        index += 1
      } else {
        guard names.contains(name), index + 1 < arguments.count, values[name] == nil else {
          throw OptionError.invalidArgument(name)
        }
        values[name] = arguments[index + 1]
        index += 2
      }
    }
    guard let audio = values["--audio"], !audio.isEmpty,
      let mode = values["--mode"], ["offline", "replay"].contains(mode),
      !(mode == "offline" && paced)
    else { throw OptionError.invalidArgument("audio or mode") }
    func seconds(_ name: String, allowZero: Bool, maximum: Double) throws -> Double? {
      guard let text = values[name] else { return nil }
      guard let value = Double(text), value.isFinite, value <= maximum,
        allowZero ? value >= 0 : value > 0
      else { throw OptionError.invalidArgument(name) }
      return value
    }
    // Explicit benchmark limits also leave ample headroom for all sample-index conversions.
    maxSeconds = try seconds("--max-seconds", allowZero: false, maximum: 604800)
    offsetSeconds = try seconds("--offset-seconds", allowZero: true, maximum: 604800) ?? 0
    wallLimitSeconds = try seconds("--wall-limit-seconds", allowZero: false, maximum: 86400) ?? 180
    self.audio = audio
    self.mode = mode
    self.paced = paced
    segmentsOutput = values["--segments-output"]
  }
}
