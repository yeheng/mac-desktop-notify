import Cocoa
import Combine

class EventMonitors {
    static let shared = EventMonitors()

    private var mouseMoveEvent: EventMonitor?
    private var mouseDownEvent: EventMonitor?
    private var keyDownEvent: EventMonitor?

    let mouseLocation: CurrentValueSubject<NSPoint, Never> = .init(.zero)
    let mouseDown: PassthroughSubject<Void, Never> = .init()
    let keyDown: PassthroughSubject<UInt16, Never> = .init()

    private init() {}

    func start() {
        guard mouseMoveEvent == nil else { return }

        mouseMoveEvent = EventMonitor(mask: .mouseMoved) { [weak self] _ in
            guard let self else { return }
            self.mouseLocation.send(NSEvent.mouseLocation)
        }
        mouseMoveEvent?.start()

        mouseDownEvent = EventMonitor(mask: .leftMouseDown) { [weak self] _ in
            guard let self else { return }
            mouseDown.send()
        }
        mouseDownEvent?.start()

        keyDownEvent = EventMonitor(mask: .keyDown) { [weak self] event in
            guard let self, let event else { return }
            keyDown.send(event.keyCode)
        }
        keyDownEvent?.start()
    }

    func stop() {
        mouseMoveEvent?.stop()
        mouseMoveEvent = nil
        mouseDownEvent?.stop()
        mouseDownEvent = nil
        keyDownEvent?.stop()
        keyDownEvent = nil
    }
}
