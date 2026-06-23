import XCTest
@testable import MacDesktopNotify

final class NotificationRecordTests: XCTestCase {
    // MARK: - normalizedActions

    func test_explicitIdPreserved() {
        let record = NotificationRecord(request: NotifyCreateRequest(
            title: "t", body: "b", type: nil, icon: nil, timeout: nil,
            actions: [
                NotificationActionRequest(id: "approve", title: "批准", style: .primary, callback: nil)
            ],
            waitForAction: nil, block: nil, actionTimeout: nil
        ))
        XCTAssertEqual(record.actions.map(\.id), ["approve"])
        XCTAssertEqual(record.actions.first?.title, "批准")
        XCTAssertEqual(record.actions.first?.style, .primary)
    }

    func test_missingIdGetsFallback() {
        let record = NotificationRecord(request: NotifyCreateRequest(
            title: "t", body: "b", type: nil, icon: nil, timeout: nil,
            actions: [NotificationActionRequest(id: nil, title: "A", style: nil, callback: nil)],
            waitForAction: nil, block: nil, actionTimeout: nil
        ))
        XCTAssertEqual(record.actions.map(\.id), ["action-1"])
    }

    func test_duplicateIdDisambiguated() {
        let record = NotificationRecord(request: NotifyCreateRequest(
            title: "t", body: "b", type: nil, icon: nil, timeout: nil,
            actions: [
                NotificationActionRequest(id: "x", title: "A", style: nil, callback: nil),
                NotificationActionRequest(id: "x", title: "B", style: nil, callback: nil)
            ],
            waitForAction: nil, block: nil, actionTimeout: nil
        ))
        // 第二个 x 冲突 → 加后缀
        XCTAssertEqual(record.actions.map(\.id), ["x", "x-2"])
    }

    func test_emptyTitleFallsBackToId() {
        let record = NotificationRecord(request: NotifyCreateRequest(
            title: "t", body: "b", type: nil, icon: nil, timeout: nil,
            actions: [NotificationActionRequest(id: "go", title: "   ", style: nil, callback: nil)],
            waitForAction: nil, block: nil, actionTimeout: nil
        ))
        XCTAssertEqual(record.actions.first?.title, "go")
    }

    // MARK: - shouldWaitForAction / block 别名

    func test_blockAliasEnablesWait() {
        let req = NotifyCreateRequest(
            title: "t", body: "b", type: nil, icon: nil, timeout: nil,
            actions: nil, waitForAction: nil, block: true, actionTimeout: nil
        )
        XCTAssertTrue(req.shouldWaitForAction)
    }

    func test_waitForActionTrueEnablesWait() {
        let req = NotifyCreateRequest(
            title: "t", body: "b", type: nil, icon: nil, timeout: nil,
            actions: nil, waitForAction: true, block: nil, actionTimeout: nil
        )
        XCTAssertTrue(req.shouldWaitForAction)
    }

    // MARK: - 基础校验

    func test_validateEmptyTitle() {
        let req = NotifyCreateRequest(
            title: "  ", body: "b", type: nil, icon: nil, timeout: nil,
            actions: nil, waitForAction: nil, block: nil, actionTimeout: nil
        )
        XCTAssertEqual(req.validate(), .emptyTitle)
    }

    func test_validateTitleTooLong() {
        let req = NotifyCreateRequest(
            title: String(repeating: "x", count: 201), body: "b", type: nil, icon: nil, timeout: nil,
            actions: nil, waitForAction: nil, block: nil, actionTimeout: nil
        )
        XCTAssertEqual(req.validate(), .titleTooLong)
    }

    func test_validateTimeoutOutOfRange() {
        let req = NotifyCreateRequest(
            title: "t", body: "b", type: nil, icon: nil, timeout: 5000,
            actions: nil, waitForAction: nil, block: nil, actionTimeout: nil
        )
        XCTAssertEqual(req.validate(), .invalidTimeout)
    }
}
