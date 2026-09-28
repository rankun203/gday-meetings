import Testing

@testable import GdayMeetings

@MainActor
struct TranscriptEditSessionTests {
    @Test func typingDoesNotPersistAndLeavingEditorCommitsOnce() {
        let session = TranscriptEditSession()
        var saved: [String] = []
        session.begin(text: "Original") { saved.append($0) }
        for text in ["R", "Re", "Revised text"] { session.draft = text }
        #expect(saved.isEmpty)
        session.finish()
        // Focus loss followed by removal from a lazy viewport must not save twice.
        session.finish()
        #expect(saved == ["Revised text"])
        #expect(!session.isEditing)
    }

    @Test func escapeCancelsAndNextEditUsesItsOwnCommitTarget() {
        let session = TranscriptEditSession()
        var first: [String] = []
        var second: [String] = []
        session.begin(text: "First meeting") { first.append($0) }
        session.draft = "Unwanted edit"
        session.finish(cancel: true)
        session.finish()
        session.begin(text: "Second meeting") { second.append($0) }
        session.draft = "Second meeting revised"
        session.finish()
        #expect(first.isEmpty)
        #expect(second == ["Second meeting revised"])
    }

    @Test func unchangedDisplayDoesNotRewriteLeadingWhitespace() {
        let session = TranscriptEditSession()
        var saved: [String] = []
        session.begin(text: "  \nTranscript") { saved.append($0) }
        #expect(session.draft == "Transcript")
        session.finish()
        #expect(saved.isEmpty)
    }

    @Test func commitMayReenterWithoutDuplicatePersistence() {
        let session = TranscriptEditSession()
        var saved: [String] = []
        session.begin(text: "Original") {
            saved.append($0)
            session.finish()
        }
        session.draft = "Changed"
        session.finish()
        #expect(saved == ["Changed"])
    }
}
