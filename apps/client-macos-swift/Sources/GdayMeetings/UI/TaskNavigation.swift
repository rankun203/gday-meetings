import SwiftUI

private struct ShowManagedTaskKey: EnvironmentKey {
    static let defaultValue: (UUID) -> Void = { _ in }
}

extension EnvironmentValues {
    var showManagedTask: (UUID) -> Void {
        get { self[ShowManagedTaskKey.self] }
        set { self[ShowManagedTaskKey.self] = newValue }
    }
}
