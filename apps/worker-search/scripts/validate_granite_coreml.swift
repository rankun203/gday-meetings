import CoreML
import Foundation

// Native compiled-model verification. Token IDs are exported by the pinned
// Python tokenizer; this does not claim parity with the app's Swift tokenizer.
struct Probe: Decodable {
    let ids: [Int]
    let mask: [Int]
    let reference: [Double]
}

func integers(_ values: [Int]) throws -> MLMultiArray {
    let array = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
    for (index, value) in values.enumerated() { array[index] = NSNumber(value: value) }
    return array
}

guard CommandLine.arguments.count == 2 else {
    fatalError("Usage: validate-granite-coreml MODEL_FOLDER")
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let probes = try JSONDecoder().decode(
    [Probe].self, from: Data(contentsOf: folder.appendingPathComponent("validation-probes.json")))
let configuration = MLModelConfiguration()
configuration.computeUnits = .all
let started = Date()
let model = try MLModel(contentsOf: folder.appendingPathComponent("SemanticEncoder.mlmodelc"), configuration: configuration)
let loadSeconds = Date().timeIntervalSince(started)
var measurements: [[String: Double]] = []
for probe in probes {
    let input = try MLDictionaryFeatureProvider(dictionary: [
        "input_ids": MLFeatureValue(multiArray: integers(probe.ids)),
        "attention_mask": MLFeatureValue(multiArray: integers(probe.mask)),
    ])
    let before = Date()
    let prediction = try model.prediction(from: input)
    guard let output = prediction.featureValue(for: "embedding")?.multiArrayValue,
        output.count == probe.reference.count
    else { fatalError("Unexpected embedding shape") }
    let actual = (0..<output.count).map { output[$0].doubleValue }
    guard actual.allSatisfy(\.isFinite) else { fatalError("Non-finite embedding") }
    let dot = zip(actual, probe.reference).reduce(0) { $0 + $1.0 * $1.1 }
    let magnitude = sqrt(actual.reduce(0) { $0 + $1 * $1 } * probe.reference.reduce(0) { $0 + $1 * $1 })
    let cosine = dot / magnitude
    let maximumError = zip(actual, probe.reference).map { abs($0 - $1) }.max() ?? 0
    guard cosine >= 0.9999, maximumError <= 0.002 else { fatalError("Native Core ML parity failed") }
    measurements.append([
        "cosine": cosine, "maximumError": maximumError, "seconds": Date().timeIntervalSince(before),
    ])
}
let result: [String: Any] = ["loadSeconds": loadSeconds, "computeUnits": "all", "probes": measurements]
let output = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(output)
FileHandle.standardOutput.write(Data([10]))
