import AppKit
import ImageIO
import SwiftUI

struct MeetingNotesWorkspace: View {
    @EnvironmentObject private var store: MeetingStore
    let meetingID: UUID
    @ViewState private var reading = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(
                "Notes View",
                selection: Binding(
                    get: { reading },
                    set: { value in
                        if store.flushNotes() { reading = value }
                    })
            ) {
                Text("Edit").tag(false)
                Text("Read").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(width: 150)
            if reading {
                NotesReadingView(meetingID: meetingID)
            }
            else {
                MeetingNotesEditor(meetingID: meetingID)
            }
        }
        .task(id: meetingID) { store.openNotes(id: meetingID) }
        .onDisappear { store.closeNotes(id: meetingID) }
        .id(meetingID)
    }
}

private struct NotesReadingView: View {
    @EnvironmentObject private var store: MeetingStore
    @EnvironmentObject private var playback: MeetingPlayback
    let meetingID: UUID
    private var markdown: String { store.meetings.first { $0.id == meetingID }?.notes ?? "" }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(NotesReadingDocument(markdown).blocks) { block in
                    HStack(alignment: .top, spacing: 12) {
                        if let time = block.time {
                            Button(NotesDocument.timestamp(time)) { play(time) }
                                .buttonStyle(.link).font(.caption).monospacedDigit()
                                .help("Play from this point")
                                .disabled(
                                    playback.isPlaybackBlocked
                                        || store.meetings.first { $0.id == meetingID }?.audioFiles.isEmpty != false
                                )
                                .frame(width: 45, alignment: .trailing)
                        }
                        else {
                            Color.clear.frame(width: 45, height: 1)
                        }
                        content(block.content).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("No notes yet. Choose Edit to add notes.").foregroundStyle(.secondary)
                }
            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor).opacity(0.6)))
    }
    @ViewBuilder private func content(_ block: NotesReadingDocument.Content) -> some View {
        switch block {
        case .text(let value): inline(value).textSelection(.enabled)
        case .literal(let value): Text(value).textSelection(.enabled)
        case .heading(let value, let level):
            inline(value).font(level <= 2 ? .title2 : .headline).bold().textSelection(.enabled)
        case .list(let value, let bullet):
            HStack(alignment: .top) {
                Text(bullet)
                inline(value).textSelection(.enabled)
            }
        case .quote(let value):
            HStack {
                Rectangle().fill(.secondary).frame(width: 3)
                inline(value).italic().textSelection(.enabled)
            }
        case .code(let value):
            Text(value).font(.system(.body, design: .monospaced)).textSelection(.enabled).padding(10).frame(
                maxWidth: .infinity, alignment: .leading
            ).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        case .divider: Divider()
        case .image(let reference):
            NotesReadingImage(
                reference: reference, directory: store.directory(for: meetingID), documentRevision: markdown)
        case .table(let rows, let alignment):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(rows[row].indices, id: \.self) { column in
                                inline(rows[row][column]).fontWeight(row == 0 ? .semibold : .regular)
                                    .textSelection(.enabled)
                                    .gridColumnAlignment(
                                        alignment[column] == .trailing
                                            ? .trailing : (alignment[column] == .center ? .center : .leading))
                            }
                        }
                        if row == 0 { Divider().gridCellUnsizedAxes(.horizontal) }
                    }
                }.padding(10).background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }
    private func inline(_ value: String) -> Text {
        Text(
            (try? AttributedString(markdown: value, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(value))
    }
    private func play(_ time: TimeInterval) {
        guard let meeting = store.meetings.first(where: { $0.id == meetingID }) else { return }
        playback.play(meeting: meeting, files: store.audioURLs(for: meeting), at: NotesDocument.playbackStart(time))
    }
}

private struct NotesReadingImage: View {
    let reference: NotesImageReference
    let directory: URL
    let documentRevision: String
    private struct LoadIdentity: Equatable {
        let reference: NotesImageReference
        let documentRevision: String
    }
    @ViewState private var image: NSImage?
    @ViewState private var failure: String?
    var body: some View {
        Group {
            if let image {
                Button {
                    if let url = try? NotesAssets.safeURL(relativePath: reference.originalPath, directory: directory) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(nsImage: image).resizable().scaledToFit().frame(
                        maxWidth: reference.width.map { CGFloat($0) } ?? 600)
                }.buttonStyle(.plain).help("Open original image").accessibilityLabel(
                    reference.alt.isEmpty ? "Image in notes" : reference.alt)
            }
            else {
                Label(failure ?? "Loading image…", systemImage: "photo").foregroundStyle(.secondary)
            }
        }
        .task(id: LoadIdentity(reference: reference, documentRevision: documentRevision)) {
            image = nil
            failure = nil
            do {
                let url = try NotesAssets.safeURL(relativePath: reference.displayPath, directory: directory)
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                    let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                        source, 0,
                        [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 1600,
                        ] as CFDictionary)
                else { throw MeetingError.message("Couldn’t read this image.") }
                image = NSImage(cgImage: thumbnail, size: .zero)
            }
            catch { failure = error.localizedDescription }
        }
    }
}
