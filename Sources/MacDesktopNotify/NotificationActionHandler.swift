import AppKit
import Foundation

/// Where an action's callback URL goes - one door for every transport.
///
/// A `notch-notify://ack` URL is a loopback: the click is recorded as a receipt
/// on disk instead of being handed to the system, so the sender can poll for
/// what was chosen. Anything else is opened as before.
///
/// Lives outside `NotificationManager` because receipts are a transport concern
/// (files on disk, a broadcast for sockets), not notification state: the
/// manager's only stake in a click is that acting on the live message retires it.
@MainActor
final class NotificationActionHandler {
    /// Posted after a receipt is recorded. userInfo carries the `NotificationAck`
    /// under key "ack". The disk receipt and this event coexist: pollers keep
    /// working, sockets get it instantly.
    static let ackDidRecord = Notification.Name("MacDesktopNotify.ackDidRecord")

    /// userInfo key: whether the receipt also reached the disk. A `false` here
    /// means the click happened but no poller will ever see it, which a socket
    /// subscriber is entitled to know instead of assuming a file exists.
    ///
    /// `nonisolated` because the observer that reads it runs inside a `@Sendable`
    /// NotificationCenter closure, before it hops to the main actor.
    nonisolated static let ackPersistedKey = "persisted"

    /// Nil until the app hands over a store, which keeps tests off the real disk.
    /// Without one, an ack click still broadcasts `ackDidRecord` - the event is
    /// promised regardless of where (or whether) the receipt is persisted.
    private let ackStore: NotificationAckStore?
    /// Test seam for receipts. Production leaves this nil and writes through `ackStore`.
    var ackWriter: ((NotificationAck) -> Void)?
    /// Test seam for URL opening; production leaves this nil and opens via NSWorkspace.
    var urlOpener: ((URL) -> Void)?

    init(ackStore: NotificationAckStore? = nil) {
        self.ackStore = ackStore
        ackStore?.pruneStale()
    }

    /// Parses and routes: ack loopbacks become receipts, everything else opens.
    ///
    /// Parsing happens here, at click time, rather than when the action was
    /// created: HTTP-pushed actions are built without it, and the URL-scheme
    /// path only pre-resolves `wantsComment` (so the panel knows to ask for a
    /// comment). One parse at the door keeps every transport's click identical.
    func execute(
        _ action: NotificationAction,
        for notification: NotchNotification,
        comment: String? = nil
    ) {
        // §2.2：script 按钮与 URL 按钮同构——点击即退役（manager.performAction
        // 负责），脚本后台执行；失败由 runActionHook 自己推诊断通知。
        if action.script != nil {
            let runner = ScriptRunner.shared
            Task { await runner.runActionHook(action: action, notification: notification, comment: comment) }
            return
        }
        guard let actionURL = action.url else { return }
        if let ack = URLNotificationParser.parseAck(actionURL) {
            let trimmed = comment?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let receipt = NotificationAck(
                token: ack.token,
                label: ack.label.isEmpty ? action.label : ack.label,
                notificationID: notification.id,
                decidedAt: Date(),
                // A blank comment is recorded as no comment: the sender asked
                // for a reason and did not get one, which is information too.
                comment: trimmed.isEmpty
                    ? nil
                    : String(trimmed.prefix(NotificationAckStore.maxCommentLength))
            )
            // The receipt is the whole point of this click: a poller waits for
            // the file, a socket subscriber takes the event. They must not be
            // told different stories, so the event carries whether it reached
            // the disk instead of assuming it did.
            var persisted = true
            if let ackWriter {
                ackWriter(receipt)
            } else if let ackStore {
                do {
                    try ackStore.write(receipt)
                } catch {
                    persisted = false
                    Diagnostics.degrade("动作回执写盘失败（token=\(receipt.token)）", error)
                }
            }
            NotificationCenter.default.post(
                name: Self.ackDidRecord,
                object: nil,
                userInfo: ["ack": receipt, Self.ackPersistedKey: persisted]
            )
        } else if let urlOpener {
            urlOpener(actionURL)
        } else {
            NSWorkspace.shared.open(actionURL)
        }
    }
}
