import CoreGraphics
import Foundation

/// Value-only input; geometry work never reads an AppKit view or layer.
struct RecordingActivityGeometryInput: Equatable, Sendable {
    let bars: [Double]
    let size: CGSize
    let start: TimeInterval?

    init(bars: [Double], size: CGSize, start: TimeInterval?) {
        // Canonical values make duplicate/stale comparisons reflexive, including invalid samples.
        self.bars = bars.map { $0.isFinite ? min(1, max(0, $0)) : 0 }
        self.size = CGSize(
            width: size.width.isFinite ? max(0, size.width) : 0,
            height: size.height.isFinite ? max(0, size.height) : 0)
        self.start = start.flatMap { $0.isFinite ? $0 : nil }
    }
}

/// Both paths are immutable copies. Only the worker owns their mutable builders.
struct RecordingActivityGeometry: @unchecked Sendable {
    let input: RecordingActivityGeometryInput
    let signal: CGPath
    let quiet: CGPath
    let step: CGFloat

    static func prepare(_ input: RecordingActivityGeometryInput) -> Self {
        let signal = CGMutablePath()
        let quiet = CGMutablePath()
        let step = input.size.width / CGFloat(max(1, input.bars.count))
        for (index, value) in input.bars.enumerated() {
            let height = max(1.5, value * max(0, input.size.height - 4))
            let rect = CGRect(
                x: CGFloat(index + 1) * step, y: (input.size.height - height) / 2,
                width: max(1, step * 0.58), height: height)
            (value > 0 ? signal : quiet).addRoundedRect(in: rect, cornerWidth: 1, cornerHeight: 1)
        }
        return Self(input: input, signal: signal.copy()!, quiet: quiet.copy()!, step: step)
    }
}

/// One worker and one replaceable latest request, even while a view is resized rapidly.
/// Cancellation invalidates the result without opening another worker slot until it finishes.
@MainActor
final class RecordingActivityPreparation {
    typealias Prepare = @Sendable (RecordingActivityGeometryInput) async -> RecordingActivityGeometry
    private let prepare: Prepare
    private let apply: (RecordingActivityGeometry) -> Void
    private var latest: RecordingActivityGeometryInput?
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    init(
        prepare: @escaping Prepare = { input in
            await Task.detached(priority: .userInitiated) {
                RecordingActivityGeometry.prepare(input)
            }.value
        },
        apply: @escaping (RecordingActivityGeometry) -> Void
    ) {
        self.prepare = prepare
        self.apply = apply
    }

    func submit(_ input: RecordingActivityGeometryInput) {
        guard latest != input else { return }
        latest = input
        if task == nil { start(input) }
    }

    func cancel() {
        latest = nil
        generation &+= 1
    }

    private func start(_ input: RecordingActivityGeometryInput) {
        let generation = generation
        let prepare = prepare
        task = Task { [weak self] in
            let geometry = await prepare(input)
            guard let self else { return }
            self.task = nil
            if self.generation == generation, self.latest == input { self.apply(geometry) }
            if self.task == nil, let latest = self.latest, self.generation != generation || latest != input {
                self.start(latest)
            }
        }
    }
}
