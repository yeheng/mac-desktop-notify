import XCTest
@testable import MacDesktopNotify

@MainActor
final class PushValidatorTests: XCTestCase {
    func testMissingTitleIsTheOnlyWholeRejection() {
        for blank in ["", "   ", "\n\t"] {
            let result = PushValidator.makeNotification(
                title: blank, body: nil, urgencyRaw: nil,
                timeout: nil, group: nil, actions: []
            )
            guard case .failure(.missingTitle) = result else {
                return XCTFail("expected .missingTitle for \(blank.debugDescription)")
            }
        }
    }

    func testTimeoutClampsToOneToSixty() throws {
        let clampedLow = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: 0.1, group: nil, actions: []
        ).get()
        XCTAssertEqual(clampedLow.timeout, 1)

        let clampedHigh = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: 999, group: nil, actions: []
        ).get()
        XCTAssertEqual(clampedHigh.timeout, 60)

        let absent = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: nil, group: nil, actions: []
        ).get()
        XCTAssertNil(absent.timeout)
    }

    func testBodyIsCappedAt5000() throws {
        let n = try PushValidator.makeNotification(
            title: "t", body: String(repeating: "x", count: 6000),
            urgencyRaw: nil, timeout: nil, group: nil, actions: []
        ).get()
        XCTAssertEqual(n.bodyMarkdown.count, 5000)
    }

    func testUnknownUrgencyFallsBackToNormal() throws {
        let n = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: "banana", timeout: nil, group: nil, actions: []
        ).get()
        XCTAssertEqual(n.urgency, .normal)
    }

    func testGroupIsTrimmedAndCapped() throws {
        let n = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: nil,
            group: "  " + String(repeating: "g", count: 100) + "  ", actions: []
        ).get()
        XCTAssertEqual(n.groupingKey, String(repeating: "g", count: 64))

        let blank = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: nil, group: "   ", actions: []
        ).get()
        XCTAssertNil(blank.groupingKey)
    }

    func testActionsTruncateNeverReject() throws {
        let longLabel = String(repeating: "L", count: 40)
        let good = URL(string: "https://example.com/a")!
        let actions = (0..<5).map { NotificationAction(label: $0 == 4 ? "  " : longLabel, url: good) }
        let n = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: nil, group: nil, actions: actions
        ).get()
        XCTAssertEqual(n.actions.count, 3, "max 3 kept")
        XCTAssertEqual(n.actions[0].label.count, 24, "label capped at 24")

        // A scheme-less URL can never be opened, so the action is dropped
        // while the valid one beside it survives.
        let schemeless = NotificationAction(label: "no scheme", url: URL(string: "example.com/x")!)
        let mixed = try PushValidator.makeNotification(
            title: "t", body: nil, urgencyRaw: nil, timeout: nil, group: nil,
            actions: [schemeless, NotificationAction(label: "ok", url: good)]
        ).get()
        XCTAssertEqual(mixed.actions.map(\.label), ["ok"], "scheme-less action dropped")
    }
}
