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
        if let ack = URLNotificationParser.parseAck(action.url) {
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
            if let ackWriter {
                ackWriter(receipt)
            } else if let ackStore {
                try? ackStore.write(receipt)
            }
            NotificationCenter.default.post(
                name: Self.ackDidRecord, object: nil, userInfo: ["ack": receipt]
            )
        } else if let urlOpener {
            urlOpener(action.url)
        } else {
            NSWorkspace.shared.open(action.url)
        }
    }
}
