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

/// The window's native sidebar action owns expansion layout and animation.
@MainActor final class LibrarySidebarNavigation: ObservableObject {
    weak var controller: NSSplitViewController?
    private(set) var requestedColumnCount: Int?
    func cancelReveal() { requestedColumnCount = nil }
    func reveal(twoColumn: Bool) {
        requestedColumnCount = twoColumn ? 2 : 3
        revealIfReady()
    }
    func revealIfReady() {
        guard let controller, controller.view.window != nil,
            controller.splitViewItems.count == requestedColumnCount
        else { return }
        requestedColumnCount = nil
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
                    controller.splitViewItems.contains(where: { $0.behavior == .sidebar }),
                    navigation.requestedColumnCount == nil
                        || controller.splitViewItems.count == navigation.requestedColumnCount
                {
                    return controller
                }
                for child in view.subviews {
                    if let controller = sidebarController(in: child) { return controller }
                }
                return nil
            }
            navigation.controller = sidebarController(in: root)
            if navigation.requestedColumnCount != nil {
                // A destination can replace the split during this SwiftUI update.
                // Run its native action after the new controller finishes mounting.
                DispatchQueue.main.async { [weak navigation] in navigation?.revealIfReady() }
            }
        }
    }
}
