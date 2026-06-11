import Foundation

// MARK: - Event Kind

/// 事件类型标识，用于订阅过滤
enum NotificationEventKind: String, CaseIterable, Sendable {
    case notificationAdded
    case notificationDismissed
    case actionTriggered
    case lockChanged
    case serviceStateChanged
    case callbackResult
}

// MARK: - Event

/// 统一通知事件枚举，涵盖所有事件类型
enum NotificationEvent: Sendable {
    case notificationAdded(NotificationRecord)
    case notificationDismissed(id: UUID, reason: NotificationDismissReason)
    case actionTriggered(NotificationActionEvent)
    case lockChanged(isLocked: Bool)
    case serviceStateChanged(APIServiceState)
    case callbackResult(notificationId: UUID, actionId: String, result: CallbackResult)

    var kind: NotificationEventKind {
        switch self {
        case .notificationAdded: return .notificationAdded
        case .notificationDismissed: return .notificationDismissed
        case .actionTriggered: return .actionTriggered
        case .lockChanged: return .lockChanged
        case .serviceStateChanged: return .serviceStateChanged
        case .callbackResult: return .callbackResult
        }
    }
}
