import SwiftUI

/// Optional diagnostic access to the production view's existing state and action.
/// The view does not observe this object, so it adds no state publication.
@MainActor
final class LibrarySidebarControl {
    private var expandedBinding: Binding<Bool>?
    private var rowsBinding: Binding<Bool>?
    private var toggleAction: ((Bool) -> Void)?
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
    }
}

/// The window's native sidebar action owns expansion layout and animation.
@MainActor final class LibrarySidebarNavigation: ObservableObject {
    weak var controller: NSSplitViewController?
    private(set) var revealPending = false
    func cancelReveal() { revealPending = false }
    func reveal() {
        revealPending = true
        revealIfReady()
    }
    func toggle(reduceMotion: Bool) {
        guard let controller else { return }
        NSAnimationContext.runAnimationGroup { context in
            if reduceMotion { context.duration = 0 }
            controller.toggleSidebar(nil)
        }
    }
    func revealIfReady() {
        guard revealPending, let controller, controller.view.window != nil
        else { return }
        revealPending = false
        if controller.splitViewItems.contains(where: { $0.behavior == .sidebar && $0.isCollapsed }) {
            controller.toggleSidebar(nil)
        }
    }
}

struct LibrarySidebarActionTarget: NSViewRepresentable {
    let navigation: LibrarySidebarNavigation
    func makeNSView(context: Context) -> TargetView { TargetView(navigation: navigation) }
    func updateNSView(_ view: TargetView, context: Context) { view.connect() }

    final class TargetView: NSView {
        let navigation: LibrarySidebarNavigation
        init(navigation: LibrarySidebarNavigation) {
            self.navigation = navigation
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            connect()
        }
        override func layout() {
            super.layout()
            connect()
        }
        func connect() {
            guard let root = window?.contentView else { return }
            func sidebarController(in view: NSView) -> NSSplitViewController? {
                if let split = view as? NSSplitView,
                    let controller = split.delegate as? NSSplitViewController,
                    controller.splitViewItems.contains(where: { $0.behavior == .sidebar })
                {
                    return controller
                }
                for child in view.subviews {
                    if let controller = sidebarController(in: child) { return controller }
                }
                return nil
            }
            navigation.controller = sidebarController(in: root)
            if navigation.revealPending {
                // Finish mounting before invoking the native sidebar action.
                DispatchQueue.main.async { [weak navigation] in navigation?.revealIfReady() }
            }
        }
    }
}
