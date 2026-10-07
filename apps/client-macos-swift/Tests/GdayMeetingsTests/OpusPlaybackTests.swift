import AVFoundation
import Foundation
import Testing

@testable import GdayMeetings

struct OpusFixture: Sendable {
    let name: String
    let channels: Int
    let base64: String
    var data: Data { Data(base64Encoded: base64)! }
    // Self-generated 440Hz tones, encoded once with ffmpeg/libopus solely as an
    // independent interoperable fixture. Tests/app/build do not invoke ffmpeg.
    static let all: [OpusFixture] = [
        .init(
            name: "10", channels: 1,
            base64:
                "T2dnUwACAAAAAAAAAABo5o/QAAAAAEoazVMBE09wdXNIZWFkAQE4AYC7AAAAAABPZ2dTAAAAAAAAAAAAAGjmj9ABAAAAQ/q7CQE8T3B1c1RhZ3MMAAAATGF2ZjYzLjEuMTAwAQAAABwAAABlbmNvZGVyPUxhdmM2My4xLjEwMCBsaWJvcHVzT2dnUwAEKREAAAAAAABo5o/QAgAAAHFAJI4KMVMeJB8mIiIgGfBzNtFjcoq/yoViUuLSZlmAKFodlauY0MNvmIhPulnc6O9e5EnOWS5rvrMtXukWqclwgtIP+56XH3KUIl7KQUmLpG+DB3duvEoVmKmWaProE1WlapKA5FO+KChCPTQ6Ef1bk5oaiP1pq5CVgDMGDKCtMYGh1SHfXS072cbE/D7CAALB7nCgs6/kBxOwtczcfPKNu0eeZKqVTJLOq1AzmZHk3nCbMqYsHebo60zjqmhk36PF2ilRlkG4yeS8Ip6/7A2yRETFa3CbMqY1RdAlp228p1wn6uCUfC7Y7EohjnoqBW+zGSNwmwezCLgH4DW1j144St58c+VRsgVXBxE9mLrLa3B43cJxzRQFqXCauUQLeAOhIDbr+vzrVEIFsAMMqcOfcBNjg5Te+mqI/V9wmrpmNUXOVLR5ANVg+R+2ldiYhtVOXoybdL1ibaB5keTecJrpiQebX2kYPVagMTIgvp33iF+Na5YXcWj8aJjbdORwBk9qZi4oyXUuNe0CBh/bLDoow+H+6cNx"
        ),
        .init(
            name: "40", channels: 1,
            base64:
                "T2dnUwACAAAAAAAAAAA0IKLLAAAAAJOcIEMBE09wdXNIZWFkAQE4AYC7AAAAAABPZ2dTAAAAAAAAAAAAADQgossBAAAAON57SQE8T3B1c1RhZ3MMAAAATGF2ZjYzLjEuMTAwAQAAABwAAABlbmNvZGVyPUxhdmM2My4xLjEwMCBsaWJvcHVzT2dnUwAEKREAAAAAAAA0IKLLAgAAAAG6im8Dd3ZieYGosDYIn8IB1m733/raAlrz9Jae0okqCZXkh0L5BnBIPa13x/Cpp0kXVzH9EdcJwoL7G0yVMUgKozhFpxkA2W/6OhspNC9O4niLg9y+iNOQD9R3CxqOwUzgRcu7y0FL6+Yjp0KsxLqrcqRMzB0bVNm1Rtcwa9B6OZsrH3Wc/Es6OGb0mo9tldNFiTPYVq9etAxbr2WlZ8xGy003Dm/wQ7OoOwaWGiISCHuKeV/cY0tjX5qy33Wc/ElJEGceM+VUD50v7SsgE41E+SeOJCOaJpfQEcmtxL0z9/x+MKLsHLUI2PSkNUdBZU55K71Pejua6agsiVDmhMxuDsOrx/Tl7cR0kdiVQHhMPgtuWGi/zh+gTiJFh1wAfUaqLbNlCUgAzBxAsnTBh48uHziPUHmsKvtN43MMRUY8PBnP3DRwfr6oirTBFxMd+/Im5FTcigA="
        ),
        .init(
            name: "60", channels: 1,
            base64:
                "T2dnUwACAAAAAAAAAADUZJ/7AAAAAJwgjSMBE09wdXNIZWFkAQE4AYC7AAAAAABPZ2dTAAAAAAAAAAAAANRkn/sBAAAAwVjd1gE8T3B1c1RhZ3MMAAAATGF2ZjYzLjEuMTAwAQAAABwAAABlbmNvZGVyPUxhdmM2My4xLjEwMCBsaWJvcHVzT2dnUwAEKREAAAAAAADUZJ/7AgAAAFig9hgCs597gzs7gaiwNgifwgHWbvff+toCWvP0lp7SiSoJleSHQvkGcEg9rXfH8KmnSRdXMf0R1wnCgvsbTJUxSAqjOEWnGQDZb/o6Gyk0L07ieIuD3L6I05AP1HcLGo7BTOBFy7vLQUvr5iOnQqzEuqtypEzMHRtU2bVG1zBr0JsrH3Wc/Es6OGb0mo9tldNFiTPYVq9etAxbr2WlZ8xGy003Dm/wQ7OoOwaWGiISCHuKeV/cY0tjX3uDOzuast91nPxJSRBnHjPlVA+dL+0rIBONRPknjiQjmiaX0BHJrcS9M/f8fjCi7By1CNj0pDVHQWVOeSu9T5rpqCyJUOaEzG4Ow6vH9OXtxHSR2JVAeEw+C25YaL/OH6BOIkWHXAB9Rqots2UJSADMHECydMGHjy4fOI9Qeawq+03jcwxFRjw8Gc/cNHB+vqiKtMEXEx378ibkVNyKAA=="
        ),
        .init(
            name: "20-stereo", channels: 2,
            base64:
                "T2dnUwACAAAAAAAAAACR/6h6AAAAAN9RjZ8BE09wdXNIZWFkAQI4AYC7AAAAAABPZ2dTAAAAAAAAAAAAAJH/qHoBAAAATVC4MgE8T3B1c1RhZ3MMAAAATGF2ZjYzLjEuMTAwAQAAABwAAABlbmNvZGVyPUxhdmM2My4xLjEwMCBsaWJvcHVzT2dnUwAEKREAAAAAAACR/6h6AgAAANIq+qYFVEVFRE58h/y0tWN7g/WwACmqMCLdQnYtj+bJ9jUG8LoxJ/gXjB/8kE+/gHCnRwljSek+kTE7l6gpkc7WEN2U7cKi8I4mwZmIqx9jwmy303O8ExNGWu8xPtB8h/8yvxVC50tqf+JTPdVRK1YhH7ScztAzm6XIzjEcH43Qb+IVZ9Uz7YwFL65tw7B+Rej3jjAQu40iGYvaE6Vyh1pCcbV8iAJh+wd2eRgbBzcErzkZ0BM4drsLE8CYmtfoB247tj6webv6i1B7CDZJTbfHD51emeEtQ6NZXH9cNvMfI/q8qeUPzJp8iAJh+wd2eRgW1rxFrICHXbZQev+51xAxSKPg50CdbO0LtDBb+OXjFQsCYjoZGwshnv9oGwnlCBS8ZaJFtzk7JrEBKnyIAmKFFO/H0cSMQAg4hmSYXN/2Ma+W+VfO582FGEVGg9tHVt1vI2CnPMHVTOsEcLFxq87kwcIzh0P5rBPyOtlayJLW9tmydO9FG0zD9Q=="
        ),
    ]
}

struct OpusPlaybackTests {
    @Test(arguments: OpusFixture.all) func decodesVariableOpusPacketDurations(fixture: OpusFixture) async throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".opus")
        try fixture.data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let metadata = try await AudioPlaybackPreparation.opusMetadata(source)
        #expect(metadata.channels == fixture.channels)
        #expect(abs(metadata.duration - Double(4081) / 48000) < 0.000001)
        let prepared = try await AudioPlaybackPreparation.prepare(source)
        defer { if prepared.temporary { try? FileManager.default.removeItem(at: prepared.url) } }
        #expect(prepared.temporary)
        let audio = try AVAudioFile(forReading: prepared.url)
        #expect(audio.length == 4081)
        #expect(Int(audio.processingFormat.channelCount) == fixture.channels)
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: UInt32(audio.length)))
        try audio.read(into: buffer)
        let samples = try #require(buffer.floatChannelData?[0])
        #expect((0..<Int(buffer.frameLength)).reduce(0.0) { $0 + Double(samples[$1] * samples[$1]) } > 1)
        #expect(try Data(contentsOf: source) == fixture.data)
        let playback = try OpusFileDecoder(source)
        let playbackBuffer = try #require(
            AVAudioPCMBuffer(pcmFormat: StreamingAudioReader.format, frameCapacity: UInt32(audio.length)))
        try playback.read(into: playbackBuffer, frames: playbackBuffer.frameCapacity)
        #expect(playbackBuffer.frameLength == buffer.frameLength)
        for channel in 0..<fixture.channels {
            let preparedSamples = try #require(buffer.floatChannelData?[channel])
            let playbackSamples = try #require(playbackBuffer.floatChannelData?[channel])
            #expect(
                (0..<Int(buffer.frameLength)).allSatisfy {
                    abs(preparedSamples[$0] - playbackSamples[$0]) < 0.000001
                })
        }
        let serverAudio = try await prepareServerAudio(source)
        #expect(serverAudio.url == source)
        #expect(!serverAudio.temporary)
        #expect(serverAudio.channels == fixture.channels)
    }
    @Test func preparesAudioWhenEndTrimmingSpansPacketsOnFinalPage() async throws {
        var data = OpusFixture.all[0].data
        var offset = 0
        while data[offset + 5] & 4 == 0 {
            let segments = Int(data[offset + 26])
            offset += 27 + segments + data[(offset + 27)..<(offset + 27 + segments)].reduce(0) { $0 + Int($1) }
        }
        // Keep 1,000 samples after the 312-sample pre-skip. The final page
        // contains several packets, so trimming crosses a packet boundary.
        let granule: UInt64 = 1312
        for index in 0..<8 { data[offset + 6 + index] = UInt8(truncatingIfNeeded: granule >> (index * 8)) }
        for index in 22..<26 { data[offset + index] = 0 }
        var crc: UInt32 = 0
        for byte in data[offset...] {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 { crc = crc & 0x8000_0000 != 0 ? (crc << 1) ^ 0x04c1_1db7 : crc << 1 }
        }
        for index in 0..<4 { data[offset + 22 + index] = UInt8(truncatingIfNeeded: crc >> (index * 8)) }
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".opus")
        try data.write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let prepared = try await AudioPlaybackPreparation.prepare(source)
        defer { try? FileManager.default.removeItem(at: prepared.url) }
        #expect(try AVAudioFile(forReading: prepared.url).length == 1000)
        let metadata = try await AudioPlaybackPreparation.opusMetadata(source)
        #expect(abs(metadata.duration - Double(1000) / 48000) < 0.000001)
    }
    @Test func rejectsCorruptTruncatedChainedAndNonOpusOgg() async throws {
        let original = OpusFixture.all[0].data
        var corrupted = original
        corrupted[corrupted.count - 1] ^= 1
        let inputs = [
            Data(original.prefix(20)), Data(original.dropLast()), corrupted, original + Data([0]), original + original,
            Data("OggSnot-an-opus-stream".utf8),
        ]
        for data in inputs {
            let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ogg")
            try data.write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            do {
                let result = try await AudioPlaybackPreparation.prepare(source)
                try? FileManager.default.removeItem(at: result.url)
                Issue.record("Invalid Ogg must be rejected")
            }
            catch { #expect(!error.localizedDescription.isEmpty) }
        }
    }
    @Test func leavesOrdinaryPlaybackFilesAlone() async throws {
        let url = URL(fileURLWithPath: "/synthetic/recording.m4a")
        let prepared = try await AudioPlaybackPreparation.prepare(url)
        #expect(prepared.url == url)
        #expect(!prepared.temporary)
    }
}
