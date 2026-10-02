import AppKit
import Combine

enum AppAppearance: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nativeAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// A preference for this Mac, independent of the meeting library.
@MainActor final class AppearanceSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var selection: AppAppearance {
        didSet {
            defaults.set(selection.rawValue, forKey: "appearance")
            apply()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = defaults.string(forKey: "appearance").flatMap(AppAppearance.init(rawValue:)) ?? .system
        apply()
    }

    private func apply() {
        // nil restores system inheritance for SwiftUI and native windows and controls.
        NSApplication.shared.appearance = selection.nativeAppearance
    }
}
