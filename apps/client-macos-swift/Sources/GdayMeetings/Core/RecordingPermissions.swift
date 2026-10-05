import AVFoundation
import AppKit

enum RecordingPermission: Equatable {
    case microphone, systemAudio
    var title: String { self == .microphone ? "Microphone Access Needed" : "System Audio Access Needed" }
    var explanation: String {
        switch self {
        case .microphone:
            return
                "Gday Meetings needs microphone access to record your voice. macOS has not made that access available to this app. No recording has started."
        case .systemAudio:
            return
                "Allow Gday Meetings to record system audio in the macOS audio-recording prompt. If access was denied, enable it in System Settings → Privacy & Security → Screen & System Audio Recording, then try again. Gday Meetings does not request screen capture."
        }
    }
}

struct RecordingPermissionError: LocalizedError {
    let permission: RecordingPermission
    var errorDescription: String? { permission.explanation }
}

@MainActor
enum RecordingPermissions {
    private static var cancellationGeneration = 0
    // HIG Privacy: ask at the explicit Record action, not on launch or preview.
    // System audio consent belongs to AudioDeviceStart of the private process tap;
    // Apple exposes no separate public tap authorization preflight/request API.
    // https://developer.apple.com/design/human-interface-guidelines/privacy
    // https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps
    static func request(microphone: Bool) async throws {
        let generation = cancellationGeneration
        NSApp.activate()
        if microphone {
            let granted: Bool
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: granted = true
            case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .audio)
            default: granted = false
            }
            guard generation == cancellationGeneration else { throw CancellationError() }
            guard granted else { throw RecordingPermissionError(permission: .microphone) }
        }
        try Task.checkCancellation()
    }
    // Quit invalidates a pending start. An OS-owned consent prompt cannot be
    // programmatically dismissed, so recheck after each consent boundary.
    static var currentCancellationGeneration: Int { cancellationGeneration }
    static func checkCancellation(since generation: Int) throws {
        guard generation == cancellationGeneration else { throw CancellationError() }
        try Task.checkCancellation()
    }
    static func cancelPendingStart() { cancellationGeneration += 1 }
    nonisolated static func permission(for error: Error) -> RecordingPermission? {
        (error as? RecordingPermissionError)?.permission
    }
}
