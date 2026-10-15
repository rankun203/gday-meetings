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
    static func dismantleNSView(_ view: RecordingActivityView, coordinator: ()) { view.tearDown() }
}

final class RecordingActivityView: NSView {
    private let moving = CALayer()
    private let signal = CAShapeLayer()
    private let quiet = CAShapeLayer()
    private var bars: [Double] = []
    private var start: TimeInterval?
    private var displayedStart: TimeInterval?
    private var displayedStep: CGFloat = 0
    private var tint = NSColor.controlAccentColor
    private var animate = false
    private lazy var preparation = RecordingActivityPreparation { [weak self] geometry in
        self?.apply(geometry)
    }
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
        self.bars = bars
        self.start = start
        let styleChanged = self.tint != tint
        self.tint = tint
        self.animate = animate
        requestGeometry()
        if styleChanged { updateColors() }
        position()
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
    func tearDown() {
        stop()
        preparation.cancel()
    }

    override func layout() {
        super.layout()
        requestGeometry()
        updateColors()
        position()
    }
    private func requestGeometry() {
        preparation.submit(RecordingActivityGeometryInput(bars: bars, size: bounds.size, start: start))
    }
    private func apply(_ geometry: RecordingActivityGeometry) {
        // Publish paths and their matching origin together; old bars never use a newer bucket's offset.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        moving.bounds = CGRect(origin: .zero, size: geometry.input.size)
        signal.frame = moving.bounds
        quiet.frame = moving.bounds
        signal.path = geometry.signal
        quiet.path = geometry.quiet
        displayedStart = geometry.input.start
        displayedStep = geometry.step
        position()
        CATransaction.commit()
    }
    private func updateColors() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            signal.fillColor = tint.cgColor
            quiet.fillColor = NSColor.secondaryLabelColor.withAlphaComponent(0.25).cgColor
        }
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }
    private func position() {
        let fraction =
            animate
            ? displayedStart.map {
                RecordingActivityHistory.scrollFraction(since: $0, at: ProcessInfo.processInfo.systemUptime)
            } ?? 0 : 0
        let offset = -fraction * displayedStep
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

    struct Configuration: Equatable {
        let microphone: Bool
        let tint: NSColor
        let animate: Bool
    }
    typealias Coordinator = RecordingMeterSubscription<Configuration>
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> RecordingActivityView { RecordingActivityView() }
    func updateNSView(_ view: RecordingActivityView, context: Context) {
        context.coordinator.update(
            meter: meter, configuration: Configuration(microphone: microphone, tint: NSColor(tint), animate: animate)
        ) { [weak view, weak meter] _, configuration in
            guard let meter else { return }
            view?.configure(
                bars: meter.activity.bars(microphone: configuration.microphone), start: meter.activity.bucketStart,
                tint: configuration.tint, animate: configuration.animate)
        }
    }
    static func dismantleNSView(_ view: RecordingActivityView, coordinator: Coordinator) {
        coordinator.cancel()
        view.tearDown()
    }
}

struct RecordingLiveLevelSurface: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let meter: RecordingMeterState
    let microphone: Bool
    let saving: Bool
    let tint: Color
    let title: String

    struct Configuration: Equatable {
        let microphone: Bool
        let saving: Bool
        let tint: NSColor
        let title: String
        let reduceMotion: Bool
    }
    typealias Coordinator = RecordingMeterSubscription<Configuration>
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> RecordingLevelView { RecordingLevelView() }
    func updateNSView(_ view: RecordingLevelView, context: Context) {
        context.coordinator.update(
            meter: meter,
            configuration: Configuration(
                microphone: microphone, saving: saving, tint: NSColor(tint), title: title, reduceMotion: reduceMotion)
        ) { [weak view] levels, configuration in
            view?.configure(
                source: configuration.microphone ? levels.microphone : levels.system, saving: configuration.saving,
                tint: configuration.tint, title: configuration.title, reduceMotion: configuration.reduceMotion)
        }
    }
    static func dismantleNSView(_ view: RecordingLevelView, coordinator: Coordinator) {
        coordinator.cancel()
        view.stop()
    }
}

/// A SwiftUI update with unchanged presentation does not replay the meter or replace its subscription.
@MainActor
final class RecordingMeterSubscription<Configuration: Equatable> {
    private weak var meter: RecordingMeterState?
    private var configuration: Configuration?
    private var subscription: AnyCancellable?
    private var receive: ((RecordingLevels, Configuration) -> Void)?

    func update(
        meter: RecordingMeterState, configuration: Configuration,
        receive: @escaping (RecordingLevels, Configuration) -> Void
    ) {
        let changedMeter = self.meter !== meter
        guard changedMeter || self.configuration != configuration else { return }
        self.configuration = configuration
        self.receive = receive
        if changedMeter {
            self.meter = meter
            subscription = meter.$levels.sink { [weak self] levels in
                guard let self, let configuration = self.configuration else { return }
                self.receive?(levels, configuration)
            }
        }
        else {
            receive(meter.levels, configuration)
        }
    }

    func cancel() {
        subscription = nil
        receive = nil
        meter = nil
        configuration = nil
    }
}

/// The bar changes layer geometry, not its view's size or Auto Layout constraints.
final class RecordingLevelView: NSView {
    private let track = CALayer()
    private let signal = CALayer()
    private var source = RecordingSourceLevel()
    private var saving = false
    private var tint = NSColor.controlAccentColor
    private static let animationKey = "recordingLevel"

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        signal.anchorPoint = .zero
        layer?.addSublayer(track)
        layer?.addSublayer(signal)
        setAccessibilityElement(true)
        setAccessibilityRole(.levelIndicator)
        setAccessibilityMinValue(-120)
        setAccessibilityMaxValue(0)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(source: RecordingSourceLevel, saving: Bool, tint: NSColor, title: String, reduceMotion: Bool = false)
    {
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
        updateLayers(animate: receiving && !reduceMotion)
    }
    override func layout() {
        super.layout()
        updateLayers()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayers()
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLayers()
    }
    func stop() {
        signal.removeAnimation(forKey: Self.animationKey)
    }
    private func updateLayers(animate: Bool = false) {
        let width = bounds.width * (saving ? 0 : source.level)
        let changed = signal.bounds.width != width
        let visible =
            window?.isVisible == true && window?.occlusionState.contains(.visible) == true
            && !isHiddenOrHasHiddenAncestor
        let shouldAnimate = animate && visible && changed
        let displayedWidth = signal.presentation()?.bounds.width ?? signal.bounds.width
        if !animate || !visible { stop() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.frame = bounds
        signal.position = .zero
        signal.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
        track.cornerRadius = bounds.height / 2
        signal.cornerRadius = bounds.height / 2
        effectiveAppearance.performAsCurrentDrawingAppearance {
            track.backgroundColor = NSColor.quaternaryLabelColor.cgColor
            signal.backgroundColor = (source.peakDB > -1 ? NSColor.systemOrange : tint).cgColor
        }
        CATransaction.commit()
        if shouldAnimate {
            // Retarget from the displayed width, including an interrupted transition.
            // Core Animation supplies display frames between the existing 10 Hz samples.
            let animation = CABasicAnimation(keyPath: "bounds.size.width")
            animation.fromValue = displayedWidth
            animation.toValue = width
            animation.duration = 0.1
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            signal.add(animation, forKey: Self.animationKey)
        }
    }
}
