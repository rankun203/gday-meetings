import AppKit
import SwiftUI
import Synchronization
import Testing

@testable import GdayMeetings

@MainActor
@Suite(.serialized)
struct PeopleVoiceReviewBarTests {
    @MainActor private final class Presentation: ObservableObject {
        @Published var reviewingVoices = false
        @Published var visible = true
    }

    private struct Harness: View {
        @ObservedObject var presentation: Presentation
        let library: VoiceLibraryStore

        var body: some View {
            VStack {
                if presentation.visible {
                    PeopleVoiceReviewBar(library: library, reviewingVoices: $presentation.reviewingVoices)
                }
                Spacer()
            }
        }
    }

    private func sample(in directory: URL) throws -> VoiceExample {
        let meetingID = UUID()
        let folder = try MeetingFolderLocation.newFolder(id: meetingID, date: Date(), directory: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("system.wav")
        try Data("synthetic audio".utf8).write(to: audio)
        return VoiceExample(
            meetingID: meetingID, speakerID: UUID(), source: "system",
            audioFile: "system.wav", audioRevision: VoiceLibraryStore.revision(url: audio), start: 0, end: 4)
    }

    private func makeWindow(store: MeetingStore, presentation: Presentation) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 240),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: Harness(presentation: presentation, library: store.voiceLibrary).environmentObject(store))
        window.orderFront(nil)
        return window
    }

    @Test func metadataChangesWhileReviewIsOpenWaitUntilCloseBeforeReading() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gday-review-open-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        let library = store.voiceLibrary
        let reads = Mutex(0)
        library.beforeReviewRead = { reads.withLock { $0 += 1 } }
        let presentation = Presentation()
        let window = makeWindow(store: store, presentation: presentation)
        defer { window.close() }
        try #require(await waitForMainActorTestCondition { reads.withLock { $0 } == 1 })
        #expect(try await library.reviewSnapshot(for: []).unnamedGroups.isEmpty)
        presentation.reviewingVoices = true
        try await Task.sleep(for: .milliseconds(100))
        #expect(library.upsert([try sample(in: directory)]))
        // Let the mounted task respond to metadata changes. The open review owns
        // reads until its binding closes; the bar must leave the cache untouched.
        try await Task.sleep(for: .milliseconds(100))
        #expect(reads.withLock { $0 } == 1)
        presentation.reviewingVoices = false
        try #require(await waitForMainActorTestCondition { reads.withLock { $0 } == 2 })
        #expect(try await library.reviewSnapshot(for: []).unnamedGroups.count == 1)
    }

    @Test func closingReviewAfterCancelledSharedFailureStartsANewRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gday-review-cancel-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        let library = store.voiceLibrary
        #expect(library.upsert([try sample(in: directory)]))
        let reads = Mutex(0)
        let release = DispatchSemaphore(value: 0)
        library.beforeReviewRead = {
            reads.withLock { $0 += 1 }
            release.wait()
            throw ServiceError("Synthetic delayed read failure")
        }
        let presentation = Presentation()
        let window = makeWindow(store: store, presentation: presentation)
        defer {
            release.signal()
            window.close()
        }
        try #require(await waitForMainActorTestCondition { reads.withLock { $0 } == 1 })
        presentation.reviewingVoices = true
        // The launcher joins the existing read. Its failure must leave a later
        // close free to retry, rather than caching a cancelled bar's result.
        let chooserRead = Task { try await library.reviewSnapshot(for: []) }
        try await Task.sleep(for: .milliseconds(100))
        library.beforeReviewRead = { reads.withLock { $0 += 1 } }
        release.signal()
        do {
            _ = try await chooserRead.value
            Issue.record("The shared mock read should fail")
        }
        catch {
            #expect(error.localizedDescription.contains("Synthetic delayed read failure"))
        }
        try await Task.sleep(for: .milliseconds(100))
        #expect(reads.withLock { $0 } == 1)
        presentation.reviewingVoices = false
        try #require(await waitForMainActorTestCondition { reads.withLock { $0 } == 2 })
        #expect(try await library.reviewSnapshot(for: []).unnamedGroups.count == 1)
    }

    @Test func emptyBarMountsAndReturningReadsEvidenceChangedWhileAway() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gday-review-remount-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MeetingStore(voiceLibraryLoading: .immediate, dataDirectory: directory)
        let library = store.voiceLibrary
        let reads = Mutex(0)
        library.beforeReviewRead = { reads.withLock { $0 += 1 } }
        let presentation = Presentation()
        let window = makeWindow(store: store, presentation: presentation)
        defer { window.close() }
        try #require(await waitForMainActorTestCondition { reads.withLock { $0 } == 1 })
        #expect(try await library.reviewSnapshot(for: []).unnamedGroups.isEmpty)
        presentation.visible = false
        try await Task.sleep(for: .milliseconds(100))
        #expect(library.upsert([try sample(in: directory)]))
        try await Task.sleep(for: .milliseconds(100))
        #expect(reads.withLock { $0 } == 1)
        presentation.visible = true
        try #require(await waitForMainActorTestCondition { reads.withLock { $0 } == 2 })
        #expect(try await library.reviewSnapshot(for: []).unnamedGroups.count == 1)
    }
}
