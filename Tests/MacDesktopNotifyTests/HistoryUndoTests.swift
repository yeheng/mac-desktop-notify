import XCTest
@testable import MacDesktopNotify

/// The deletion journal's edge cases: undo must never resurrect what a
/// confirmed wipe removed, and a group that was re-pushed after the delete
/// must not fork into two entries.
@MainActor
final class HistoryUndoTests: SettingsIsolatedTestCase {

    private func make(_ title: String, group: String? = nil) -> CardPayload {
        CardPayload(title: title, bodyMarkdown: "body", urgency: .normal, timeout: 60, group: group)
    }

    /// Delete one message (journaled), then confirm 清空历史: the pending
    /// journal must die with the wipe — the confirmation says 不可撤销.
    func testClearPastHistoryKillsThePendingUndoJournal() {
        let m = NotificationManager()
        m.push(make("a"))
        m.push(make("b"))
        for card in Array(m.presentations) {
            m.retireCard(card.item.id, readOnRetire: false)
        }
        m.removeHistory(id: m.history.first { $0.title == "a" }!.id)
        XCTAssertEqual(m.history.map(\.title), ["b"])

        m.clearPastHistory()
        XCTAssertTrue(m.history.isEmpty)

        m.undoDeletion()
        XCTAssertTrue(m.history.isEmpty, "undo must not resurrect a confirmed wipe")
    }

    /// Delete a group entry, re-push the group, then undo: the stale entry
    /// stays deleted — the live one is the group's current report.
    func testUndoDoesNotForkARegrownGroup() {
        let m = NotificationManager()
        m.push(make("构建中", group: "ci"))
        let firstID = m.history.first!.id
        m.removeHistory(id: firstID)

        m.push(make("构建成功", group: "ci"))
        XCTAssertEqual(m.history.count, 1)
        XCTAssertEqual(m.history.first?.occurrences, 1, "a cleared group restarts its count")

        m.undoDeletion()
        XCTAssertEqual(m.history.count, 1, "the regrown group must not fork")
        XCTAssertEqual(m.history.first?.title, "构建成功")
    }
}
