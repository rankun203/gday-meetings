import os

/// Fixed review operation names keep recordings and identities out of Instruments.
enum ReviewPerformance {
    static let signposter = OSSignposter(subsystem: "com.gdaymeetings.macos", category: .pointsOfInterest)
}
