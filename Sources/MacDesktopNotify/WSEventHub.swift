import Foundation
import Observation

/// Registry of live WebSocket sessions plus the manager-event bridge.
/// One hub per app: every `.ackDidRecord` and `unreadCountDidChange`
/// becomes one JSON frame fanned out to every connected client.
@MainActor
final class WSEventHub {
    private var sessions: [WSSession] = []
    private let manager: NotificationManager

    /// Written once in `init` and read only in `deinit`, which Swift 6 runs
    /// from a nonisolated context — hence the `nonisolated(unsafe)`.
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    init(manager: NotificationManager) {
        self.manager = manager
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: NotificationManager.unreadCountDidChange, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.broadcast(["type": "unreadCount", "count": self.manager.unreadCount])
                }
            },
            center.addObserver(
                forName: NotificationManager.ackDidRecord, object: nil, queue: .main
            ) { [weak self] notification in
                // `Notification` is not Sendable, so the payload is unpacked
                // before hopping to the main actor.
                let ack = notification.userInfo?["ack"] as? NotificationAck
                Task { @MainActor [weak self, ack] in
                    guard let self, let ack else { return }
                    self.broadcast([
                        "type": "ack",
                        "token": ack.token,
                        "label": ack.label,
                        "notificationID": ack.notificationID.uuidString,
                        "decidedAt": ack.decidedAt.timeIntervalSince1970,
                    ])
                }
            },
        ]
    }

    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }

    func register(_ session: WSSession) {
        // A session the handshake already rejected is dead on arrival; keeping
        // it would leave an entry nothing ever unregisters.
        guard !session.isClosed else { return }
        sessions.append(session)
        session.send(json: ["type": "hello", "unreadCount": manager.unreadCount])
    }

    func unregister(_ session: WSSession) {
        sessions.removeAll { $0 === session }
    }

    func broadcast(_ json: [String: Any]) {
        for session in sessions { session.send(json: json) }
    }
}
