import AppKit
import Combine
import SwiftUI

@main
struct GdayMeetingsApp: App {
    @NSApplicationDelegateAdaptor(MeetingsAppDelegate.self) private var delegate
    @StateObject private var store = UIPreview.makeStore()
    @StateObject private var playback = MeetingPlayback()

    var body: some Scene {
        WindowGroup(id: "main") {
            PreviewContainer { LibraryView() }.environmentObject(store).environmentObject(playback)
                .onAppear {
                    delegate.store = store
                    if UIPreview.enabled, !playback.hasSelection, let meeting = store.meetings.first {
                        playback.select(meeting: meeting, files: store.audioURLs(for: meeting))
                    }
                }
                .onReceive(store.$isStartingRecording.combineLatest(store.$recordingID, store.$isFinalizingRecording)) {
                    starting, recording, saving in
                    playback.setRecordingActive(starting || recording != nil || saving)
                }
                .onReceive(store.$meetings) { meetings in playback.reconcile(meetings: meetings) }
                .frame(minWidth: 900, minHeight: 600)
        }
        .defaultSize(width: 1200, height: 800)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            // HIG: expose frequent commands in the menu bar, with standard shortcuts.
            // https://developer.apple.com/design/human-interface-guidelines/designing-for-macos
            CommandGroup(replacing: .newItem) {
                Button("New Meeting") { _ = store.createMeeting(title: "Untitled Meeting") }
                    .keyboardShortcut("n")
                Button("Import Audio…") { MeetingPanels.importAudio(store) }.keyboardShortcut("o")
                Button("Import Existing Gday Library…") { MeetingPanels.importLegacy(store) }
                Button("Import Meeting Archive…") { MeetingPanels.importArchive(store) }
            }
            CommandMenu("Recording") {
                Button(store.recordingID == nil ? "Start Recording" : "Stop Recording") {
                    if store.recordingID == nil {
                        Task { await store.startRecording() }
                    }
                    else {
                        Task { await store.stopRecording() }
                    }
                }.keyboardShortcut("r", modifiers: [.command, .shift])
                    // Background jobs never disable this; only the recording lifecycle does.
                    .disabled(
                        store.isStartingRecording || store.isFinalizingRecording
                            || (store.recordingID == nil && !store.canStartRecording))
            }
            CommandGroup(after: .help) {
                Button("Export Logs") { MeetingPanels.exportLogs(store) }
            }
            CommandMenu("Playback") {
                Button(playback.isPlaying ? "Pause" : "Play") { playback.togglePlayPause() }
                    .disabled(!playback.hasSelection || playback.isPlaybackBlocked || playback.isLoading)
                Button("Back 15 Seconds") { playback.skip(by: -15) }
                    .disabled(!playback.hasSelection || playback.isPlaybackBlocked || playback.isLoading)
                Button("Forward 15 Seconds") { playback.skip(by: 15) }
                    .disabled(!playback.hasSelection || playback.isPlaybackBlocked || playback.isLoading)
            }
        }
        // HIG: app-specific preferences live in a separate standard Settings window.
        // https://developer.apple.com/design/human-interface-guidelines/settings
        Settings { SettingsView().environmentObject(store).environmentObject(playback) }
        MenuBarExtra {
            RecordingMenuView().environmentObject(store).environmentObject(playback)
        } label: {
            if store.recordingID == nil {
                Image(nsImage: MenuBarArtwork.waveform).accessibilityLabel("Gday Meetings")
            }
            else {
                Image(systemName: "record.circle.fill").accessibilityLabel("Gday Meetings — Recording")
            }
        }
    }
}

private enum MenuBarArtwork {
    // Match the Rust client's 18-point template, with vector drawing for Retina.
    // Keep these bar dimensions in sync with desktop.rs waveform_icon().
    static let waveform: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            for (x, height) in [(2, 6), (5, 12), (8, 16), (11, 10), (14, 4)] {
                NSBezierPath(rect: NSRect(x: x, y: (18 - height) / 2, width: 2, height: height)).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}

@MainActor
final class MeetingsAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: MeetingStore?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        Task {
            await store.finalizeForQuit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

private struct RecordingMenuView: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        if store.isFinalizingRecording {
            Text("Saving recording…")
        }
        else if store.isStartingRecording {
            Text("Starting recording…")
        }
        else if let started = store.recordingStartedAt {
            Text("Recording since \(started.formatted(date: .omitted, time: .shortened))")
        }
        Group {
            if #available(macOS 15.0, *), store.recordingID == nil {
                // Native Option-key menu replacement, including while the menu is open.
                // https://developer.apple.com/documentation/swiftui/view/modifierkeyalternate(_:_:)
                recordingButton.modifierKeyAlternate(.option) {
                    Button(action: openRecordingSetup) {
                        Label("New Recording…", systemImage: "slider.horizontal.3")
                    }
                }
            }
            else {
                recordingButton
            }
        }.disabled(
            store.isStartingRecording || store.isFinalizingRecording
                || (store.recordingID == nil && !store.canStartRecording))
        Button {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        } label: {
            Label("Show app", systemImage: "macwindow")
        }
        Divider()
        Button {
            NSApp.terminate(nil)
        } label: {
            Label("Quit Gday Meetings", systemImage: "power")
        }.keyboardShortcut("q")
    }

    private func openRecordingSetup() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        store.presentsRecordingSetup = true
    }

    private var recordingButton: some View {
        Button {
            if store.recordingID == nil {
                // macOS 14 lacks modifierKeyAlternate; preserve Option-click behavior.
                if #unavailable(macOS 15.0), NSEvent.modifierFlags.contains(.option) {
                    openRecordingSetup()
                    return
                }
                Task {
                    await store.startRecording()
                    if store.recordingID == nil, store.errorMessage != nil || store.recordingPermissionNeeded != nil {
                        openWindow(id: "main")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
            else {
                Task { await store.stopRecording() }
            }
        } label: {
            Label(
                store.recordingID == nil ? "Start Recording" : "Stop Recording",
                systemImage: store.recordingID == nil ? "record.circle" : "stop.circle")
        }
    }
}
