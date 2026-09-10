import XCTest
@testable import MacDesktopNotify

/// 脚本回填写入活卡片后，展示规则必须按新字段重新推导。
/// 前两个用例在修复前失败（见 2026-09-09 评审 #1）。
@MainActor
final class BackfillRulesTests: SettingsIsolatedTestCase {
    private func makeLiveCard(_ m: NotificationManager, timeout: Double = 60) -> NotchNotification {
        var n = NotchNotification(title: "⏳ 脚本生成中", bodyMarkdown: "orig",
                                  urgency: .normal, timeout: timeout)
        n.script = "ci"
        m.push(n)
        return n
    }

    func testBackfillToCriticalGetsCriticalRules() async throws {
        let m = NotificationManager()
        m.dwellTiming.autoClose = .milliseconds(80)
        let n = makeLiveCard(m)

        m.update(id: n.id) { $0.urgency = .critical }
        XCTAssertEqual(m.current?.urgency, .critical)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNotNil(m.current, "critical 不得自动收起")
    }

    func testBackfillAddingActionsGetsOperableRules() async throws {
        let m = NotificationManager()
        m.dwellTiming.autoClose = .milliseconds(80)
        let n = makeLiveCard(m)

        m.update(id: n.id) {
            $0.actions = [NotificationAction(label: "批准", url: URL(string: "https://x.test")!)]
        }
        XCTAssertFalse(m.current!.actions.isEmpty)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNotNil(m.current, "可操作卡片不得自动收起")
    }

    /// 反向：critical 被脚本降级为普通消息后，必须重新拿到 dwell 预算。
    /// 面板先关掉——打开的面板会按设计 hold 住倒计时。
    func testBackfillToNormalGetsAFreshDwell() async throws {
        let m = NotificationManager()
        var n = NotchNotification(title: "critical", bodyMarkdown: "x", urgency: .critical, timeout: nil)
        n.script = "ci"
        m.push(n)
        XCTAssertNotNil(m.current)

        m.update(id: n.id) { $0.urgency = .normal; $0.timeout = 0.1 }
        m.dismissPanel()
        XCTAssertNotNil(m.current, "关面板后消息仍活着")

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertNil(m.current, "降级为普通消息后必须重新拥有 dwell 预算并按时退役")
    }
}
