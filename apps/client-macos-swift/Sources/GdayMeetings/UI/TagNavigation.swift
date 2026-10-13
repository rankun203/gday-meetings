import SwiftUI

private struct ShowTagKey: EnvironmentKey {
    static let defaultValue: (UUID) -> Void = { _ in }
}

extension EnvironmentValues {
    var showTag: (UUID) -> Void {
        get { self[ShowTagKey.self] }
        set { self[ShowTagKey.self] = newValue }
    }
}

struct TagAssociationChip: View {
    let name: String
    let removalHelp: String
    var open: () -> Void
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .frame(minWidth: 28, minHeight: 28)
                    .contentShape(Rectangle())
            }
            .help(removalHelp)
            .accessibilityLabel("Remove tag \(name)")
            Button(action: open) {
                Text(name)
                    .padding(.trailing, 8)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
            }
            .help("Show meetings tagged \(name)")
            .accessibilityLabel("Open tag \(name)")
        }
        .font(.callout)
        .buttonStyle(.plain)
        .background(.quaternary, in: Capsule())
    }
}
