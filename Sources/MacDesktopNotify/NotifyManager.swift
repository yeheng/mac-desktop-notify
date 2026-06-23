import Combine
import Foundation
import SwiftUI

// MARK: - Notify Type

enum NotifyType: String, Codable, CaseIterable {
    case info, success, warning, error

    var iconColor: Color {
        switch self {
        case .info: return .cyan
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }

    var iconBackgroundColor: Color {
        iconColor.opacity(0.15)
    }

    var systemImageName: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.circle.fill"
        }
    }
}

// MARK: - Request / Response Models

struct NotifyCreateRequest: Codable {
    let title: String
    let body: String
    let type: NotifyType?
    let icon: String?
    let timeout: TimeInterval?
    let actions: [NotificationActionRequest]?
    let waitForAction: Bool?
    let block: Bool?
    let actionTimeout: TimeInterval?

    var shouldWaitForAction: Bool {
        waitForAction == true || block == true
    }

    // MARK: - Input Validation

    enum ValidationError: String, Sendable {
        case emptyTitle = "title must not be empty"
        case titleTooLong = "title too long (max 200 characters)"
        case bodyTooLong = "body too long (max 5000 characters)"
        case invalidTimeout = "timeout must be between 0 and 3600"
    }

    func validate() -> ValidationError? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty { return .emptyTitle }
        if trimmedTitle.count > 200 { return .titleTooLong }
        if body.count > 5000 { return .bodyTooLong }
        if let timeout, timeout < 0 || timeout > 3600 { return .invalidTimeout }
        return nil
    }
}

struct NotificationActionRequest: Codable, Equatable {
    let id: String?
    let title: String
    let style: NotificationActionStyle?
    let callback: NotificationActionCallback?
}

enum NotificationActionStyle: String, Codable, Equatable {
    case normal
    case primary
    case destructive
}

// MARK: - Action Models
// NotificationActionCallback / NotificationActionCallbackType / FileAction 已移至
// Sources/MacDesktopNotify/Callbacks/NotificationActionCallback.swift（tagged union，校验下沉到解码器）

struct NotificationAction: Identifiable, Codable, Equatable {
    let id: String
    var title: String
    var style: NotificationActionStyle
    var callback: NotificationActionCallback?
}

struct NotificationActionSelection: Codable, Equatable {
    let notificationId: UUID
    let actionId: String
    let actionTitle: String
    let selectedAt: Date
}

struct NotificationActionEvent: Sendable {
    let notification: NotificationRecord
    let action: NotificationAction
    let selection: NotificationActionSelection
}

enum NotificationDismissReason: String, Codable, Equatable {
    case removed
    case cleared
    case timeout
    case actionSelected
    case waitTimeout
}

// MARK: - Notification Record

struct NotificationRecord: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var body: String
    var type: NotifyType
    var icon: String?
    var createdAt: Date
    var timeout: TimeInterval
    var actions: [NotificationAction]

    init(
        id: UUID = UUID(),
        title: String,
        body: String,
        type: NotifyType = .info,
        icon: String? = nil,
        createdAt: Date = Date(),
        timeout: TimeInterval = 8,
        actions: [NotificationAction] = []
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.type = type
        self.icon = icon
        self.createdAt = createdAt
        self.timeout = timeout
        self.actions = actions
    }

    init(request: NotifyCreateRequest) {
        let fallbackTimeout: TimeInterval = request.shouldWaitForAction ? 0 : 8
        self.init(
            title: request.title,
            body: request.body,
            type: request.type ?? .info,
            icon: request.icon,
            timeout: request.timeout ?? fallbackTimeout,
            actions: Self.normalizedActions(from: request.actions ?? [])
        )
    }

    private static func normalizedActions(from requests: [NotificationActionRequest]) -> [NotificationAction] {
        var seen = Set<String>()

        return requests.enumerated().map { index, request in
            let fallbackId = "action-\(index + 1)"
            let rawId = request.id?.trimmingCharacters(in: .whitespacesAndNewlines)
            var id = rawId?.isEmpty == false ? rawId! : fallbackId
            if seen.contains(id) {
                id = "\(id)-\(index + 1)"
            }
            seen.insert(id)

            let rawTitle = request.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return NotificationAction(
                id: id,
                title: rawTitle.isEmpty ? id : rawTitle,
                style: request.style ?? .normal,
                callback: request.callback
            )
        }
    }
}

// MARK: - API Service State

enum APIServiceState: Equatable {
    case stopped
    case running(host: String, port: UInt16, authRequired: Bool)
    case failed(host: String, port: UInt16, message: String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }

    var statusText: String {
        switch self {
        case .stopped:
            return "未启动"
        case .running(let host, let port, let authRequired):
            return authRequired ? "\(host):\(port) / token" : "\(host):\(port)"
        case .failed(_, _, let message):
            return message
        }
    }

    var statusImageName: String {
        isRunning ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }
}

// MARK: - NotifyManager

@MainActor
@Observable
final class NotifyManager {
    private let maxItems = 100
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    /// 统一事件总线
    let eventBus: NotificationEventBus

    private(set) var items: [NotificationRecord] = []
    /// 已看通知的 id 集合。横幅列表由 `unseenItems` 派生，不再单独维护 bannerIDs。
    private(set) var seenIDs: Set<UUID> = []
    var isLocked = false
    var serviceState: APIServiceState = .stopped

    /// 未看通知（最新在前）—— 横幅堆叠的数据源，从 `items` 派生，不独立存储。
    var unseenItems: [NotificationRecord] {
        items.filter { !seenIDs.contains($0.id) }
    }

    init(eventBus: NotificationEventBus) {
        self.eventBus = eventBus
    }

    // MARK: - Mutation Methods

    func add(_ item: NotificationRecord) {
        items.insert(item, at: 0)
        if items.count > maxItems {
            items.removeLast(items.count - maxItems)
        }
        eventBus.publish(.notificationAdded(item))

        // 清理因溢出被移除的项对应的 timeout 任务
        let activeIDs = Set(items.map(\.id))
        for id in timeoutTasks.keys where !activeIDs.contains(id) {
            timeoutTasks.removeValue(forKey: id)?.cancel()
        }

        guard item.timeout > 0 else { return }
        let id = item.id
        let timeout = item.timeout
        timeoutTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            self?.remove(id: id, reason: .timeout)
        }
    }

    func remove(id: UUID, reason: NotificationDismissReason = .removed) {
        let hadItem = items.contains { $0.id == id }
        guard hadItem else { return }

        timeoutTasks.removeValue(forKey: id)?.cancel()
        seenIDs.remove(id)

        items.removeAll { $0.id == id }

        if reason != .actionSelected {
            eventBus.publish(.notificationDismissed(id: id, reason: reason))
        }
    }

    func clear() {
        timeoutTasks.values.forEach { $0.cancel() }
        timeoutTasks.removeAll()

        let removedIDs = items.map(\.id)
        guard !removedIDs.isEmpty else { return }

        seenIDs.removeAll()

        items.removeAll()
        removedIDs.forEach { eventBus.publish(.notificationDismissed(id: $0, reason: .cleared)) }
    }

    func triggerAction(notificationID: UUID, actionID: String) {
        guard let item = items.first(where: { $0.id == notificationID }),
              let action = item.actions.first(where: { $0.id == actionID })
        else { return }

        let selection = NotificationActionSelection(
            notificationId: notificationID,
            actionId: action.id,
            actionTitle: action.title,
            selectedAt: Date()
        )
        eventBus.publish(.actionTriggered(NotificationActionEvent(
            notification: item,
            action: action,
            selection: selection
        )))
        remove(id: notificationID, reason: .actionSelected)
    }

    func toggleLock() {
        isLocked.toggle()
        eventBus.publish(.lockChanged(isLocked: isLocked))
    }

    func updateServiceState(_ state: APIServiceState) {
        serviceState = state
        eventBus.publish(.serviceStateChanged(state))
    }

    // MARK: - Seen State

    /// 标记单条通知为已看（从横幅移除，但保留在主列表）。
    func markSeen(id: UUID) {
        guard items.contains(where: { $0.id == id }) else { return }
        seenIDs.insert(id)
    }

    /// 标记所有通知为已看（进入面板时调用）。
    func markAllSeen() {
        seenIDs.formUnion(items.map(\.id))
    }

    func snapshot() -> [NotificationRecord] {
        items
    }
}
