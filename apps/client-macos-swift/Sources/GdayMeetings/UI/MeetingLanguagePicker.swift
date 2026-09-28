import AppKit
import SwiftUI

/// Meeting language is an offline app setting, independent of provider configuration.
struct MeetingLanguagePicker: View {
    var title = "Language"
    @Binding var selection: String
    var compact = false
    @ViewState private var showInformation = false

    var body: some View {
        HStack(spacing: 4) {
            if compact {
                languagePicker.labelsHidden().frame(width: compactWidth)
            }
            else {
                languagePicker
            }
            Button {
                showInformation.toggle()
            } label: {
                Image(systemName: "info.circle").frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Language Information")
            .help("About transcription language")
            .popover(isPresented: $showInformation) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Transcription Language").font(.headline)
                    Text("Choose the language spoken in the recording.")
                    Text(
                        "Each transcription provider checks whether it supports this language before processing audio."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                .font(.callout).padding(16).frame(width: 280, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var compactWidth: CGFloat {
        let label = AppLanguages.name(for: selection) as NSString
        let textWidth = label.size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width
        // Reserve native menu padding and arrows; long names remain bounded.
        return min(280, max(80, ceil(textWidth) + 40))
    }
    private var languagePicker: some View {
        // Display an alias as its standard choice without rewriting the saved code.
        Picker(
            title,
            selection: Binding(
                get: { AppLanguages.canonicalCode(for: selection) ?? selection },
                set: { selection = $0 })
        ) {
            ForEach(AppLanguages.all) { Text($0.name).tag($0.code) }
            if AppLanguages.canonicalCode(for: selection) == nil {
                Text(AppLanguages.name(for: selection)).tag(selection).disabled(true)
            }
        }.pickerStyle(.menu)
    }
}
