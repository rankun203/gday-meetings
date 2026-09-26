import SwiftUI

/// Optional diagnostic access to the production view's existing state and action.
/// The view does not observe this object, so it adds no state publication.
@MainActor
final class LibrarySidebarControl {
    private var expandedBinding: Binding<Bool>?
    private var rowsBinding: Binding<Bool>?
    private var toggleAction: ((Bool) -> Void)?
    var completed: ((Bool) -> Void)?
    var isConnected: Bool { toggleAction != nil }
    var expanded: Bool { expandedBinding?.wrappedValue ?? true }
    var rowsVisible: Bool { rowsBinding?.wrappedValue ?? true }

    func connect(expanded: Binding<Bool>, rows: Binding<Bool>, toggle: @escaping (Bool) -> Void) {
        expandedBinding = expanded
        rowsBinding = rows
        toggleAction = toggle
    }
    func toggle(reduceMotion: Bool) { toggleAction?(reduceMotion) }
    func disconnect() {
        expandedBinding = nil
        rowsBinding = nil
        toggleAction = nil
        completed = nil
    }
}
