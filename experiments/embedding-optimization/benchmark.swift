import CoreML
import Foundation

struct Probe: Decodable {
    let ids: [Int]
    let mask: [Int]
    let reference: [Double]?
}
func elapsed(_ start: Double) -> Double { (ProcessInfo.processInfo.systemUptime - start) * 1000 }
func tensor(_ values: [Int]) throws -> MLMultiArray {
    let a = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .int32)
    for (i,v) in values.enumerated() { a[i] = NSNumber(value:v) }
    return a
}
let args = CommandLine.arguments
precondition((5...6).contains(args.count), "benchmark MODEL.mlmodelc PROBES.json COMPUTE OUTPUT.json [FUNCTION]")
let probes = try JSONDecoder().decode([Probe].self, from: Data(contentsOf: URL(fileURLWithPath:args[2])))
let config = MLModelConfiguration()
if args.count == 6 { config.functionName = args[5] }
switch args[3] {
case "cpu": config.computeUnits = .cpuOnly
case "gpu": config.computeUnits = .cpuAndGPU
case "ane": config.computeUnits = .cpuAndNeuralEngine
default: config.computeUnits = .all
}
let before = ProcessInfo.processInfo.systemUptime
let model = try MLModel(contentsOf: URL(fileURLWithPath:args[1]), configuration:config)
let load = elapsed(before)
let inputs = try probes.map { p in
    try MLDictionaryFeatureProvider(dictionary: ["input_ids":MLFeatureValue(multiArray:tensor(p.ids)),
                                                "attention_mask":MLFeatureValue(multiArray:tensor(p.mask))])
}
func predict(_ index: Int) throws -> ([Double], Double) {
    let start = ProcessInfo.processInfo.systemUptime
    let prediction = try model.prediction(from:inputs[index])
    let ms = elapsed(start)
    let a = prediction.featureValue(for:"embedding")!.multiArrayValue!
    return ((0..<a.count).map { a[$0].doubleValue },ms)
}
let first = try predict(0)
var vectors: [[Double]] = []
var times: [Double] = []
var cosines: [Double] = []
var maxError = 0.0
var nonfinite = 0
for i in probes.indices {
    let (vector,ms) = try predict(i)
    nonfinite += vector.filter { !$0.isFinite }.count
    vectors.append(vector.map { $0.isFinite ? $0 : 0 })
    times.append(ms)
    if let ref = probes[i].reference {
        let dot = zip(vector,ref).reduce(0) { $0 + $1.0*$1.1 }
        let norm = sqrt(vector.reduce(0) { $0+$1*$1 } * ref.reduce(0) { $0+$1*$1 })
        if dot.isFinite && norm > 0 { cosines.append(dot/norm) }
        maxError = max(maxError,zip(vector,ref).map { abs($0-$1) }.filter(\.isFinite).max() ?? 0)
    }
}
var warm: [Double] = []
for i in 0..<50 { warm.append(try predict(i % min(probes.count,7)).1) }
func quantile(_ a:[Double], _ q:Double) -> Double { a.sorted()[min(a.count-1,Int(Double(a.count-1)*q))] }
let result: [String:Any] = ["loadMs":load,"firstPredictionMs":first.1,"warmP50Ms":quantile(warm,0.5),
 "warmP95Ms":quantile(warm,0.95),"warmTimesMs":warm,"encodeTimesMs":times,"vectors":vectors,
 "minimumCosine":cosines.min() ?? 0,"maximumError":maxError,"nonfiniteValues":nonfinite,
 "computeUnits":args[3],"os":ProcessInfo.processInfo.operatingSystemVersionString,
 "thermalState":ProcessInfo.processInfo.thermalState.rawValue]
try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys]).write(to:URL(fileURLWithPath:args[4]))
print("load=\(load)ms first=\(first.1)ms warmMedian=\(quantile(warm,0.5))ms nonfinite=\(nonfinite)")
