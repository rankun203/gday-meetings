import AppKit
import SwiftUI

/// A quiet, noninteractive total at the end of a collection.
struct ListCountFooter: View {
    let text: String

    static func text(count: Int, singular: String, plural: String) -> String {
        "\(count.formatted()) \(count == 1 ? singular : plural)"
    }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 40)
            .accessibilityAddTraits(.isStaticText)
    }
}

final class NativeListCountCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")

    static func make(in table: NSTableView, text: String) -> NativeListCountCell {
        let identifier = NSUserInterfaceItemIdentifier("list-count")
        let cell =
            table.makeView(withIdentifier: identifier, owner: nil) as? NativeListCountCell
            ?? NativeListCountCell()
        cell.identifier = identifier
        cell.label.stringValue = text
        return cell
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.font = .preferredFont(forTextStyle: .caption1)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
