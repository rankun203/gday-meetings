import Accelerate
import Foundation

/// CLSP's fixed Kaldi frontend. Ported from torchaudio 2.8 compliance/kaldi.py;
/// see ThirdParty licenses. No amplitude scaling, dithering, or cepstral mean subtraction.
struct CLSPAudioFeatures: Sendable {
    let values: [Float]
    let frameCount: Int
    static let bins = 128
}

final class CLSPAudioFrontend {
    private let fft: vDSP_DFT_Setup
    private let window: [Float]
    private let banks: [[(Int, Float)]]

    init() throws {
        guard let fft = vDSP_DFT_zop_CreateSetup(nil, 512, .FORWARD) else {
            throw ServiceError("Couldn’t prepare voice search audio processing.")
        }
        self.fft = fft
        window = (0..<400).map { i in
            powf(0.5 - 0.5 * cosf(Float(i) * (2 * Float.pi / 399)), 0.85)
        }
        let low = 1127 * log(1 + 20.0 / 700)
        let high = 1127 * log(1 + 7600.0 / 700)
        let delta = Float((high - low) / 129)
        banks = (0..<128).map { bin in
            let left = Float(low) + Float(bin) * delta
            let center = Float(low) + Float(bin + 1) * delta
            let right = Float(low) + Float(bin + 2) * delta
            return (0..<256).compactMap { frequency in
                let mel = 1127 * logf(1 + Float(frequency) * 31.25 / 700)
                let weight = max(0, min((mel - left) / (center - left), (right - mel) / (right - center)))
                return weight > 0 ? (frequency, weight) : nil
            }
        }
    }
    deinit { vDSP_DFT_DestroySetup(fft) }

    /// Call on one owned worker; Accelerate scratch state is not shared across predictions.
    func features(_ samples: [Float]) throws -> CLSPAudioFeatures {
        guard (4000...480_000).contains(samples.count), samples.allSatisfy(\.isFinite) else {
            throw ServiceError("Voice search needs 0.25–30 seconds of finite 16 kHz mono audio.")
        }
        let count = (samples.count + 80) / 160
        var output = [Float]()
        output.reserveCapacity(count * 128)
        var frame = [Float](repeating: 0, count: 400)
        var real = [Float](repeating: 0, count: 512)
        let imaginary = [Float](repeating: 0, count: 512)
        var realOut = imaginary
        var imaginaryOut = imaginary
        var power = [Float](repeating: 0, count: 256)
        for index in 0..<count {
            try Task.checkCancellation()
            let start = index * 160 - 120
            for sample in 0..<400 {
                var position = start + sample
                if position < 0 { position = -position - 1 }
                if position >= samples.count { position = 2 * samples.count - position - 1 }
                frame[sample] = samples[position]
            }
            var mean: Float = 0
            vDSP_meanv(frame, 1, &mean, 400)
            for sample in 0..<400 { frame[sample] -= mean }
            for sample in 0..<400 {
                real[sample] = (frame[sample] - 0.97 * frame[max(0, sample - 1)]) * window[sample]
            }
            vDSP_DFT_Execute(fft, real, imaginary, &realOut, &imaginaryOut)
            for frequency in 0..<256 {
                // Match abs().pow(2), including the Float32 magnitude rounding.
                let magnitude = hypotf(realOut[frequency], imaginaryOut[frequency])
                power[frequency] = magnitude * magnitude
            }
            for bank in banks {
                var energy: Float = 0
                for (frequency, weight) in bank { energy += power[frequency] * weight }
                output.append(logf(max(Float.ulpOfOne, energy)))
            }
        }
        return .init(values: output, frameCount: count)
    }
}

/// torchaudio.functional.resample's sinc_interp_hann defaults, including zero
/// padding, reduced-ratio phases, width 6, rolloff 0.99 and ceiling output length.
enum CLSPSincResampler {
    static func resample(_ samples: [Float], from sourceRate: Int, to targetRate: Int = 16000) throws -> [Float] {
        guard (8000...192000).contains(sourceRate), (8000...192000).contains(targetRate),
            samples.count <= sourceRate * 30, samples.allSatisfy(\.isFinite)
        else { throw ServiceError("The audio format is not supported for voice search.") }
        if sourceRate == targetRate { return samples }
        func gcd(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcd(b, a % b) }
        let divisor = gcd(sourceRate, targetRate)
        let original = sourceRate / divisor
        let target = targetRate / divisor
        let base = Double(min(original, target)) * 0.99
        let width = Int(ceil(6 * Double(original) / base))
        let length = 2 * width + original
        var kernels = [(offset: Int, values: [Float])]()
        kernels.reserveCapacity(target)
        for phase in 0..<target {
            try Task.checkCancellation()
            // The Hann-sinc kernel is zero outside six zero crossings. Keep only its
            // compact support so unusual coprime rates cannot allocate a dense rate² table.
            let center = Double(phase) * Double(original) / Double(target) + Double(width)
            let lower = max(0, Int(floor(center)) - width)
            let upper = min(length, Int(ceil(center)) + width + 1)
            let values = (lower..<upper).map { index in
                let offset = Float(index - width) / Float(original)
                let time = min(Float(6), max(-6, (-Float(phase) / Float(target) + offset) * Float(base)))
                let cosine = cosf(time * Float.pi / 6 / 2)
                let angle = time * Float.pi
                let sinc: Float = angle == 0 ? 1 : sinf(angle) / angle
                return sinc * (cosine * cosine * Float(base / Double(original)))
            }
            kernels.append((lower, values))
        }
        let count = Int(ceil(Double(samples.count) * Double(target) / Double(original)))
        var output = [Float](repeating: 0, count: count)
        for index in 0..<count {
            if index % 16000 == 0 { try Task.checkCancellation() }
            let phase = index % target
            let kernel = kernels[phase]
            let start = index / target * original - width + kernel.offset
            let lower = max(0, -start)
            let upper = min(kernel.values.count, samples.count - start)
            var value: Float = 0
            if lower < upper {
                for tap in lower..<upper { value += samples[start + tap] * kernel.values[tap] }
            }
            output[index] = value
        }
        return output
    }
}
