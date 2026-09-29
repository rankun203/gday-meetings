import AppKit
import Combine
import QuartzCore
import SwiftUI

/// Immutable bar geometry is rebuilt only on samples/resize; display ticks translate it.
struct RecordingActivitySurface: NSViewRepresentable {
    let bars: [Double]
    let bucketStart: TimeInterval?
    let tint: Color
    let animate: Bool

    func makeNSView(context: Context) -> RecordingActivityView { RecordingActivityView() }
    func updateNSView(_ view: RecordingActivityView, context: Context) {
        view.configure(bars: bars, start: bucketStart, tint: NSColor(tint), animate: animate)
    }
    static func dismantleNSView(_ view: RecordingActivityView, coordinator: ()) { view.stop() }
}

final class RecordingActivityView: NSView {
    private let moving = CALayer()
    private let signal = CAShapeLayer()
    private let quiet = CAShapeLayer()
    private var bars: [Double] = []
    private var start: TimeInterval?
    private var tint = NSColor.controlAccentColor
    private var animate = false
    private var dirty = true
    private var drawnSize = CGSize.zero
    private var link: CADisplayLink?
    private final class Target: NSObject {
        weak var view: RecordingActivityView?
        @objc func tick(_ link: CADisplayLink) { view?.position() }
    }
    private let target = Target()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        moving.anchorPoint = .zero
        layer?.addSublayer(moving)
        moving.addSublayer(quiet)
        moving.addSublayer(signal)
        target.view = self
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    deinit { link?.invalidate() }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(bars: [Double], start: TimeInterval?, tint: NSColor, animate: Bool) {
        if self.bars != bars {
            self.bars = bars
            dirty = true
        }
        self.start = start
        self.tint = tint
        self.animate = animate
        // Update paths and origin together, avoiding a one-frame jump on bucket rollover.
        layout()
        updateClock()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateClock()
    }
    private func updateClock() {
        guard animate, start != nil, window != nil else {
            stop()
            return
        }
        guard link == nil else { return }
        let link = displayLink(target: target, selector: #selector(Target.tick(_:)))
        self.link = link
        link.add(to: .main, forMode: .common)
    }
    func stop() {
        link?.invalidate()
        link = nil
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if dirty || drawnSize != bounds.size {
            dirty = false
            drawnSize = bounds.size
            let activePath = CGMutablePath()
            let quietPath = CGMutablePath()
            let step = bounds.width / CGFloat(max(1, bars.count))
            for (index, value) in bars.enumerated() {
                let height = max(1.5, min(1, max(0, value)) * (bounds.height - 4))
                let rect = CGRect(
                    x: CGFloat(index + 1) * step, y: (bounds.height - height) / 2,
                    width: max(1, step * 0.58), height: height)
                (value > 0 ? activePath : quietPath).addRoundedRect(in: rect, cornerWidth: 1, cornerHeight: 1)
            }
            moving.bounds = CGRect(origin: .zero, size: bounds.size)
            signal.frame = moving.bounds
            quiet.frame = moving.bounds
            signal.path = activePath
            quiet.path = quietPath
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            signal.fillColor = tint.cgColor
            quiet.fillColor = NSColor.secondaryLabelColor.withAlphaComponent(0.25).cgColor
        }
        position()
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
    private func position() {
        let fraction =
            animate
            ? start.map {
                RecordingActivityHistory.scrollFraction(since: $0, at: ProcessInfo.processInfo.systemUptime)
            } ?? 0 : 0
        let offset = -fraction * bounds.width / CGFloat(max(1, bars.count))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        moving.transform = CATransform3DMakeTranslation(offset, 0, 0)
        CATransaction.commit()
    }
}

/// Owns a direct meter subscription so amplitude updates do not invalidate SwiftUI layout.
struct RecordingLiveActivitySurface: NSViewRepresentable {
    let meter: RecordingMeterState
    let microphone: Bool
    let tint: Color
    let animate: Bool

    final class Coordinator {
        var subscription: AnyCancellable?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> RecordingActivityView { RecordingActivityView() }
    func updateNSView(_ view: RecordingActivityView, context: Context) {
        context.coordinator.subscription = meter.$levels.sink { [weak view] _ in
            view?.configure(
                bars: meter.activity.bars(microphone: microphone), start: meter.activity.bucketStart,
                tint: NSColor(tint), animate: animate)
        }
    }
    static func dismantleNSView(_ view: RecordingActivityView, coordinator: Coordinator) {
        coordinator.subscription = nil
        view.stop()
    }
}

struct RecordingLiveLevelSurface: NSViewRepresentable {
    let meter: RecordingMeterState
    let microphone: Bool
    let saving: Bool
    let tint: Color
    let title: String

    final class Coordinator {
        var subscription: AnyCancellable?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> RecordingLevelView { RecordingLevelView() }
    func updateNSView(_ view: RecordingLevelView, context: Context) {
        context.coordinator.subscription = meter.$levels.sink { [weak view] levels in
            view?.configure(
                source: microphone ? levels.microphone : levels.system, saving: saving,
                tint: NSColor(tint), title: title)
        }
    }
    static func dismantleNSView(_ view: RecordingLevelView, coordinator: Coordinator) {
        coordinator.subscription = nil
    }
}

/// The bar changes layer geometry, not its view's size or Auto Layout constraints.
final class RecordingLevelView: NSView {
    private let track = CALayer()
    private let signal = CALayer()
    private var source = RecordingSourceLevel()
    private var saving = false
    private var tint = NSColor.controlAccentColor

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(track)
        layer?.addSublayer(signal)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityMinValue(-120)
        setAccessibilityMaxValue(0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(source: RecordingSourceLevel, saving: Bool, tint: NSColor, title: String) {
        self.source = source
        self.saving = saving
        self.tint = tint
        let receiving =
            !saving && source.enabled && !source.muted && source.hasSamples && !source.stale && !source.reconnecting
        let status = saving ? (source.enabled ? "Finalizing" : "Not recorded") : source.statusText
        setAccessibilityLabel(title)
        setAccessibilityValue(receiving ? source.rmsDB : -120)
        setAccessibilityValueDescription(receiving ? "\(status), \(Int(source.rmsDB)) decibels" : status)
        toolTip = status
        updateLayers()
    }
    override func layout() {
        super.layout()
        updateLayers()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayers()
    }
    private func updateLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        signal.frame = CGRect(x: 0, y: 0, width: bounds.width * (saving ? 0 : source.level), height: bounds.height)
        track.cornerRadius = bounds.height / 2
        signal.cornerRadius = bounds.height / 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            signal.backgroundColor = (source.peakDB > -1 ? NSColor.systemOrange : tint).cgColor
        }
        CATransaction.commit()
    }
}
