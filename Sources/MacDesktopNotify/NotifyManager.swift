import Foundation
import SwiftUI

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

struct NotifyCreateRequest: Codable {
    let title: String
    let body: String
    let type: NotifyType?
    let icon: String?
    let timeout: TimeInterval?
}

struct NotificationRecord: Identifiable, Codable, Equatable {
    let id: UUID
    var title: String
    var body: String
    var type: NotifyType
    var icon: String?
    var createdAt: Date
    var timeout: TimeInterval

    init(
        id: UUID = UUID(),
        title: String,
        body: String,
        type: NotifyType = .info,
        icon: String? = nil,
        createdAt: Date = Date(),
        timeout: TimeInterval = 8
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.type = type
        self.icon = icon
        self.createdAt = createdAt
        self.timeout = timeout
    }

    init(request: NotifyCreateRequest) {
        self.init(
            title: request.title,
            body: request.body,
            type: request.type ?? .info,
            icon: request.icon,
            timeout: request.timeout ?? 8
        )
    }
}

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

@MainActor
@Observable
final class NotifyManager {
    private let maxItems = 100

    private(set) var items: [NotificationRecord] = []
    var isLocked = false
    var serviceState: APIServiceState = .stopped
    var onNewNotification: ((NotificationRecord) -> Void)?
    var onLockChanged: ((Bool) -> Void)?

    func add(_ item: NotificationRecord) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            items.insert(item, at: 0)
            if items.count > maxItems {
                items.removeLast(items.count - maxItems)
            }
        }
        onNewNotification?(item)

        guard item.timeout > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + item.timeout) { [weak self] in
            Task { @MainActor in
                self?.remove(id: item.id)
            }
        }
    }

    func remove(id: UUID) {
        withAnimation(.easeInOut(duration: 0.3)) {
            items.removeAll { $0.id == id }
        }
    }

    func clear() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            items.removeAll()
        }
    }

    func toggleLock() {
        isLocked.toggle()
        onLockChanged?(isLocked)
    }

    func updateServiceState(_ state: APIServiceState) {
        serviceState = state
    }

    func snapshot() -> [NotificationRecord] {
        items
    }
}
