import AppKit
import Combine
import SwiftUI

@main
struct GdayMeetingsApp: App {
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.librarySearchAction) private var librarySearchAction
    @FocusedValue(\.newMeetingNotesAction) private var newMeetingNotesAction
    @NSApplicationDelegateAdaptor(MeetingsAppDelegate.self) private var delegate
    @StateObject private var store = UIPreview.makeStore()
    @StateObject private var playback = MeetingPlayback()
    @StateObject private var appearance = AppearanceSettings()
    @StateObject private var providerDrafts = ProviderDraftCoordinator()

    var body: some Scene {
        Window("Meetings", id: "main") {
            PreviewContainer { LibraryView() }.environmentObject(store).environmentObject(playback)
                .environmentObject(appearance)
                .disabled(store.isChangingLibrary || store.isPreparingToQuit)
                .onAppear {
                    delegate.store = store
                    delegate.providerDrafts = providerDrafts
                    delegate.mainWindowLifecycle.openMainWindow = { openWindow(id: "main") }
                }
                .task {
                    await store.previewPreparation?.value
                    if UIPreview.enabled,
                        !UIPreviewPerformanceFixtures.flag("--preview-chrome-only", infoKey: "GdayPreviewChromeOnly"),
                        !playback.hasSelection, let meeting = store.meetings.first
                    {
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
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            SidebarCommands()
            CommandGroup(after: .textEditing) {
                Button("Find Meetings…") { librarySearchAction?() }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(librarySearchAction == nil)
            }
            // HIG: expose frequent commands in the menu bar, with standard shortcuts.
            // https://developer.apple.com/design/human-interface-guidelines/designing-for-macos
            CommandGroup(replacing: .newItem) {
                Button("New Recording…") {
                    openWindow(id: "main")
                    store.presentsRecordingSetup = true
                }
                .keyboardShortcut("n")
                .disabled(!store.canStartRecording)
                Button("New Meeting Notes") { newMeetingNotesAction?() }
                    .disabled(!store.libraryWritable || newMeetingNotesAction == nil)
                Button("Import Audio or Video…") { MeetingPanels.importAudio(store) }.keyboardShortcut("o")
                    .disabled(
                        !store.libraryWritable || store.recordingID != nil || store.isStartingRecording
                            || store.isFinalizingRecording || store.isImportingAudio)
                Divider()
                Button("Import Existing Gday Library…") { MeetingPanels.importLegacy(store) }
                    .disabled(!store.libraryWritable)
                Button("Import Meeting Archive…") { MeetingPanels.importArchive(store) }
                    .disabled(!store.libraryWritable)
                Button("Open Meetings Folder") {
                    if !NSWorkspace.shared.open(store.dataDirectory) {
                        store.errorMessage = "Could not open the meetings folder in Finder."
                    }
                }
            }
            CommandMenu("Format") {
                Button("Bold") { NSApp.sendAction(#selector(NotesTextView.markdownBold(_:)), to: nil, from: nil) }
                    .keyboardShortcut("b")
                Button("Italic") { NSApp.sendAction(#selector(NotesTextView.markdownItalic(_:)), to: nil, from: nil) }
                    .keyboardShortcut("i")
                Button("Link…") { NSApp.sendAction(#selector(NotesTextView.markdownLink(_:)), to: nil, from: nil) }
                    .keyboardShortcut("k")
            }
            CommandMenu("Recording") {
                Button(store.recordingID == nil ? "New Recording…" : "Stop & Save") {
                    if store.recordingID == nil {
                        openWindow(id: "main")
                        store.presentsRecordingSetup = true
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
                Button("Follow Logs") { MeetingPanels.followLogs(store) }
                Button("Export Logs") { MeetingPanels.exportLogs(store) }
            }
            CommandMenu("Playback") {
                Button("Play From Line") {
                    NSApp.sendAction(#selector(NotesTextView.playFromLine(_:)), to: nil, from: nil)
                }.keyboardShortcut(.return)
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
        Settings {
            SettingsView().environmentObject(store).environmentObject(playback).environmentObject(appearance)
                .environmentObject(providerDrafts)
        }
        MenuBarExtra {
            RecordingMenuView().environmentObject(store).environmentObject(playback)
        } label: {
            if store.recordingID == nil {
                Image(nsImage: MenuBarArtwork.normal).accessibilityLabel("Gday Meetings")
            }
            else {
                Image(nsImage: MenuBarArtwork.recording).accessibilityLabel("Gday Meetings — Recording")
            }
        }
    }
}

enum MenuBarArtwork {
    static let normal = image(recording: false)
    static let recording = image(recording: true)

    private static func image(recording: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: true) { bounds in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: bounds.minX, y: bounds.minY)
            context.scaleBy(x: bounds.width / 24, y: bounds.height / 24)
            context.setFillColor(NSColor.black.cgColor)
            context.setStrokeColor(NSColor.black.cgColor)

            let band = CGMutablePath()
            band.move(to: CGPoint(x: 3.6, y: 7.3))
            band.addCurve(
                to: CGPoint(x: 20.4, y: 7.3),
                control1: CGPoint(x: 4.1, y: -0.1), control2: CGPoint(x: 19.9, y: -0.1))
            context.addPath(band)
            context.setLineWidth(1.1)
            context.setLineCap(.round)
            context.strokePath()

            let head = CGMutablePath()
            head.move(to: CGPoint(x: 7.5, y: 10.4))
            head.addCurve(to: CGPoint(x: 1.5, y: 7), control1: CGPoint(x: 7, y: 7), control2: CGPoint(x: 4, y: 5))
            head.addCurve(
                to: CGPoint(x: 2, y: 15.7), control1: CGPoint(x: -1, y: 9.5), control2: CGPoint(x: -0.3, y: 14))
            head.addCurve(
                to: CGPoint(x: 5, y: 15.8), control1: CGPoint(x: 3, y: 16.5), control2: CGPoint(x: 4.3, y: 16.3))
            head.addCurve(to: CGPoint(x: 12, y: 22), control1: CGPoint(x: 4.5, y: 20), control2: CGPoint(x: 7, y: 22))
            head.addCurve(
                to: CGPoint(x: 19, y: 15.8), control1: CGPoint(x: 17, y: 22), control2: CGPoint(x: 19.5, y: 20))
            head.addCurve(
                to: CGPoint(x: 22, y: 15.7), control1: CGPoint(x: 19.7, y: 16.3), control2: CGPoint(x: 21, y: 16.5))
            head.addCurve(
                to: CGPoint(x: 22.5, y: 7), control1: CGPoint(x: 24.3, y: 14), control2: CGPoint(x: 25, y: 9.5))
            head.addCurve(to: CGPoint(x: 16.5, y: 10.4), control1: CGPoint(x: 20, y: 5), control2: CGPoint(x: 17, y: 7))
            head.addCurve(to: CGPoint(x: 7.5, y: 10.4), control1: CGPoint(x: 15, y: 7), control2: CGPoint(x: 9, y: 7))
            head.closeSubpath()
            context.addPath(head)
            if recording {
                // The stop mark is transparent so the menu bar supplies its appearance.
                context.addPath(
                    CGPath(
                        roundedRect: CGRect(x: 9.4, y: 13, width: 5.2, height: 5.2),
                        cornerWidth: 0.7, cornerHeight: 0.7, transform: nil))
            }
            context.drawPath(using: .eoFill)
            return true
        }
        image.isTemplate = true
        return image
    }
}

@MainActor
final class MeetingsAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: MeetingStore?
    weak var providerDrafts: ProviderDraftCoordinator?
    let mainWindowLifecycle = MainWindowLifecycle()
    private var voiceLibraryPreparationScheduled = false

    func applicationDidUpdate(_ notification: Notification) {
        guard !voiceLibraryPreparationScheduled, let store,
            NSApp.windows.contains(where: { MainWindowLifecycle.isUserFacing($0) && $0.isVisible })
        else { return }
        voiceLibraryPreparationScheduled = true
        // Begin storage loading after AppKit updates the first visible window.
        Task { await store.prepareVoiceLibraryAfterLaunch() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        mainWindowLifecycle.requestRestoration()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        // Dock reopen can arrive while already active, without another activation callback.
        !mainWindowLifecycle.requestRestoration()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        guard providerDrafts?.confirmLeaving(store: store) != false else { return .terminateCancel }
        mainWindowLifecycle.isTerminating = true
        Task {
            let saved = await store.finalizeForQuit()
            await SearchLog.flush()
            if !saved { mainWindowLifecycle.isTerminating = false }
            sender.reply(toApplicationShouldTerminate: saved)
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
            if store.recordingID == nil {
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
            NSApp.activate()
        } label: {
            Label("Show App", systemImage: "macwindow")
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
        NSApp.activate()
        store.presentsRecordingSetup = true
    }

    private var recordingButton: some View {
        Button {
            if store.recordingID == nil {
                Task {
                    await store.startRecording()
                    if store.recordingID == nil, store.errorMessage != nil || store.recordingPermissionNeeded != nil {
                        openWindow(id: "main")
                        NSApp.activate()
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
