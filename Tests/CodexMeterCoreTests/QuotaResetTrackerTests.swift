import XCTest
@testable import CodexMeterCore

final class QuotaResetTrackerTests: XCTestCase {
    private let fiveHours = 5 * 60
    private let weekly = 7 * 24 * 60
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    func testInitialObservationDoesNotTriggerReset() {
        var tracker = QuotaResetTracker()
        let resetsAt = start.addingTimeInterval(Double(fiveHours) * 60)
        let window100 = makeWindow(id: "codex-primary", used: 0, resetsAt: resetsAt, duration: fiveHours)
        let window50 = makeWindow(id: "codex-secondary", used: 50, resetsAt: resetsAt, duration: weekly)

        let initialResets = tracker.evaluate(windows: [window100, window50])
        XCTAssertTrue(initialResets.isEmpty)
    }

    func testQuotaRestoredToFullTriggersReset() {
        var tracker = QuotaResetTracker()
        let firstReset = start.addingTimeInterval(Double(fiveHours) * 60)
        let usedWindow = makeWindow(id: "codex-primary", used: 60, resetsAt: firstReset, duration: fiveHours)

        _ = tracker.evaluate(windows: [usedWindow])

        let secondReset = firstReset.addingTimeInterval(Double(fiveHours) * 60)
        let restoredWindow = makeWindow(id: "codex-primary", used: 0, resetsAt: secondReset, duration: fiveHours)

        let resets = tracker.evaluate(windows: [restoredWindow])
        XCTAssertEqual(resets.count, 1)
        XCTAssertEqual(resets.first?.id, "codex-primary")
    }

    func testQuotaConsumptionDoesNotTriggerReset() {
        var tracker = QuotaResetTracker()
        let resetsAt = start.addingTimeInterval(Double(fiveHours) * 60)
        let window1 = makeWindow(id: "codex-primary", used: 20, resetsAt: resetsAt, duration: fiveHours)
        _ = tracker.evaluate(windows: [window1])

        let window2 = makeWindow(id: "codex-primary", used: 40, resetsAt: resetsAt, duration: fiveHours)
        let resets = tracker.evaluate(windows: [window2])
        XCTAssertTrue(resets.isEmpty)
    }

    func testSlidingResetAtFullQuotaDoesNotTriggerReset() {
        var tracker = QuotaResetTracker()
        let firstReset = start.addingTimeInterval(Double(fiveHours) * 60)
        let window1 = makeWindow(id: "codex-primary", used: 0, resetsAt: firstReset, duration: fiveHours)
        _ = tracker.evaluate(windows: [window1])

        // Sliding reset when unused moves reset timestamp forward
        let secondReset = firstReset.addingTimeInterval(3600)
        let window2 = makeWindow(id: "codex-primary", used: 0, resetsAt: secondReset, duration: fiveHours)
        let resets = tracker.evaluate(windows: [window2])
        XCTAssertTrue(resets.isEmpty)
    }

    func testResetClearsStateAcrossAccountBoundary() {
        var tracker = QuotaResetTracker()
        let resetsAt = start.addingTimeInterval(Double(fiveHours) * 60)
        let usedWindow = makeWindow(id: "codex-primary", used: 70, resetsAt: resetsAt, duration: fiveHours)
        _ = tracker.evaluate(windows: [usedWindow])

        tracker.reset()

        let fullWindow = makeWindow(id: "codex-primary", used: 0, resetsAt: resetsAt, duration: fiveHours)
        let resets = tracker.evaluate(windows: [fullWindow])
        XCTAssertTrue(resets.isEmpty)
    }

    private func makeWindow(
        id: String,
        used: Int,
        resetsAt: Date,
        duration: Int
    ) -> CodexUsageWindow {
        CodexUsageWindow(
            id: id,
            name: "Test Window",
            usedPercent: used,
            windowDurationMins: duration,
            resetsAt: resetsAt
        )
    }
}
