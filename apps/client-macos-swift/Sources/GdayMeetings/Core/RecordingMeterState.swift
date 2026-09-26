import Foundation

/// Levels and recent activity for the recording in progress, updated at the
/// capture meter rate (10 Hz). This is deliberately separate from MeetingStore:
/// publishing through the store invalidated every view observing it (library
/// list, meeting editor, menus, toolbar, and scene commands) ten times a second,
/// which saturated the main thread. Only the recording meters observe this object.
@MainActor
final class RecordingMeterState: ObservableObject {
    @Published private(set) var levels = RecordingLevels()
    let status = RecordingMeterStatus()
    /// Changes together with `levels`, so one publication covers both.
    private(set) var activity = RecordingActivityHistory()

    /// Starts a new recording's meters with the chosen sources and no history.
    func reset(_ levels: RecordingLevels = RecordingLevels()) {
        activity = RecordingActivityHistory()
        self.levels = levels
        status.update(levels)
    }

    func deliver(_ levels: RecordingLevels, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        activity.append(levels, at: time)
        self.levels = levels
        status.update(levels)
    }
}

/// Only changes that affect text, controls, or accessibility status enter SwiftUI layout.
@MainActor
final class RecordingMeterStatus: ObservableObject {
    @Published private(set) var levels = RecordingLevels()

    func update(_ incoming: RecordingLevels) {
        var status = incoming
        // Loudness, including quiet/receiving transitions, belongs to the native meter.
        // Neither changes the surrounding layout, controls, or source availability.
        status.microphone.rmsDB = -120
        status.system.rmsDB = -120
        status.microphone.peakDB = -120
        status.system.peakDB = -120
        if levels != status { levels = status }
    }
}
