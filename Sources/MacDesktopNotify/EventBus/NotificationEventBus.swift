import Combine
import Foundation

// MARK: - Event Bus Protocol

/// 事件发布协议
@MainActor
protocol EventPublishing: AnyObject {
    func publish(_ event: NotificationEvent)
}

/// 事件订阅协议
@MainActor
protocol EventSubscribing: AnyObject {
    func subscribe(
        for kind: NotificationEventKind,
        handler: @escaping (NotificationEvent) -> Void
    ) -> AnyCancellable

    func publisher(for kind: NotificationEventKind) -> AnyPublisher<NotificationEvent, Never>
}

/// 事件总线协议
@MainActor
protocol EventBusProtocol: EventPublishing, EventSubscribing {}

// MARK: - Default Implementation

/// 基于 Combine 的统一事件总线
@MainActor
final class NotificationEventBus: EventBusProtocol, @unchecked Sendable {
    private let subject = PassthroughSubject<NotificationEvent, Never>()

    func publish(_ event: NotificationEvent) {
        subject.send(event)
    }

    func subscribe(
        for kind: NotificationEventKind,
        handler: @escaping (NotificationEvent) -> Void
    ) -> AnyCancellable {
        subject
            .filter { $0.kind == kind }
            .sink { handler($0) }
    }

    func publisher(for kind: NotificationEventKind) -> AnyPublisher<NotificationEvent, Never> {
        subject
            .filter { $0.kind == kind }
            .eraseToAnyPublisher()
    }
}
