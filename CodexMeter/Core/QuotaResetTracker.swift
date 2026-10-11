import Foundation

/// Decides when quota windows have reset to full quota or begun a new replenishment cycle.
struct QuotaResetTracker: Codable, Equatable, Sendable {
    private struct WindowState: Codable, Equatable, Sendable {
        var remainingPercent: Int
        var resetsAt: Date?
    }

    private var states: [String: WindowState] = [:]

    init() {}

    mutating func reset() {
        states.removeAll()
    }

    /// Evaluates current windows against previous observations and returns windows that underwent a reset.
    mutating func evaluate(windows: [CodexUsageWindow]) -> [CodexUsageWindow] {
        var resetWindows: [CodexUsageWindow] = []

        for window in windows {
            let key = window.historyID
            if let previous = states[key] {
                let hasReset = previous.remainingPercent < 100 && (
                    window.remainingPercent == 100 ||
                    (window.remainingPercent > previous.remainingPercent &&
                     QuotaCycleDetection.startsNewCycle(
                        previousRemaining: previous.remainingPercent,
                        previousReset: previous.resetsAt,
                        currentRemaining: window.remainingPercent,
                        currentReset: window.resetsAt
                     ))
                )

                if hasReset {
                    resetWindows.append(window)
                }
            }

            states[key] = WindowState(
                remainingPercent: window.remainingPercent,
                resetsAt: window.resetsAt
            )
        }

        return resetWindows
    }
}
