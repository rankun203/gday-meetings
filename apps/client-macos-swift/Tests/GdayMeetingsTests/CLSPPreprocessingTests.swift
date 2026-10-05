import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

struct CLSPPreprocessingTests {
    private struct Golden: Decodable {
        struct FBank: Decodable {
            let name: String
            let input: [Float]
            let expected: [Float]
            let frames: Int
        }
        struct Resample: Decodable {
            let rate: Int
            let input: [Float]
            let expected: [Float]
        }
        struct Tokens: Decodable {
            let text: String
            let ids: [Int32]
        }
        let fbank: [FBank]
        let resample: [Resample]
        let tokens: [Tokens]
    }
    private func golden() throws -> Golden {
        let url = try #require(Bundle.module.url(forResource: "golden", withExtension: "json", subdirectory: "CLSP"))
        return try JSONDecoder().decode(Golden.self, from: Data(contentsOf: url))
    }
    @Test func kaldiFeaturesMatchPinnedPythonReference() throws {
        let frontend = try CLSPAudioFrontend()
        for item in try golden().fbank {
            let actual = try frontend.features(item.input)
            #expect(actual.frameCount == item.frames)
            #expect(actual.values.count == item.expected.count)
            let error = zip(actual.values, item.expected).map { abs($0 - $1) }.max() ?? 0
            let rms = sqrt(
                zip(actual.values, item.expected).reduce(Float(0)) { $0 + pow($1.0 - $1.1, 2) }
                    / Float(item.expected.count))
            print("CLSP fbank \(item.name) maximum error: \(error), RMS: \(rms)")
            if let folder = ProcessInfo.processInfo.environment["GDAY_CLSP_DIAGNOSTIC_DIRECTORY"] {
                try JSONEncoder().encode(actual.values).write(
                    to: URL(fileURLWithPath: folder).appendingPathComponent(item.name + ".json"))
            }
            #expect(error <= 5e-4)
            #expect(rms <= 5e-5)
        }
    }
    @Test func sincResamplingMatchesPinnedPythonReference() throws {
        for item in try golden().resample {
            let actual = try CLSPSincResampler.resample(item.input, from: item.rate)
            #expect(actual.count == item.expected.count)
            let error = zip(actual, item.expected).map { abs($0 - $1) }.max() ?? 0
            print("CLSP resample \(item.rate) maximum error: \(error)")
            #expect(error <= 1e-5)
        }
    }
    @Test(.enabled(if: ProcessInfo.processInfo.environment["GDAY_CLSP_TOKENIZER_DIRECTORY"] != nil))
    func localRobertaTokenIDsMatchPinnedPythonReference() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["GDAY_CLSP_TOKENIZER_DIRECTORY"])
        let tokenizer = try await CLSPTokenizer(directory: URL(fileURLWithPath: path))
        for item in try golden().tokens {
            let actual = try tokenizer.encode(item.text)
            #expect(actual.ids == item.ids)
            #expect(actual.attentionMask == Array(repeating: 1, count: item.ids.count))
        }
        let padded = try tokenizer.encode("voice", paddedTo: 12)
        #expect(padded.ids.count == 12)
        #expect(padded.ids.suffix(8) == Array(repeating: 1, count: 8))
        #expect(padded.attentionMask.suffix(8) == Array(repeating: 0, count: 8))
    }
    @Test func nativeLoaderPreservesSourceRangeAndAveragesEveryChannel() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_3_0_A))
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channelLayout: layout)
        do {
            var fileSettings = format.settings
            fileSettings[AVLinearPCMIsNonInterleaved] = false
            let file = try AVAudioFile(forWriting: url, settings: fileSettings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
            buffer.frameLength = 8000
            let channels = try #require(buffer.floatChannelData)
            for channel in 0..<3 {
                for frame in 0..<8000 {
                    channels[channel][frame] = (1600..<5600).contains(frame) ? (channel == 1 ? 0.5 : 0.125) : 0
                }
            }
            try file.write(from: buffer)
        }
        let actual = try CLSPAudioLoader.load(url: url, start: 0.1, duration: 0.25)
        #expect(actual.count == 4000)
        #expect(actual.allSatisfy { $0 == 0.25 })
        #expect(throws: (any Error).self) { try CLSPAudioLoader.load(url: url, start: 0.49, duration: 0.25) }
        #expect(throws: (any Error).self) { try CLSPAudioLoader.load(url: url, start: .infinity, duration: 0.25) }
    }

}
