import Combine
import Foundation

/// 基于 Combine 的统一事件总线。
/// （删除 EventPublishing/EventSubscribing/EventBusProtocol 三个未被引用的协议 —— YAGNI）
@MainActor
final class NotificationEventBus: @unchecked Sendable {
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
