import Foundation
import Network

/// A live WebSocket connection. Takes over an accepted NWConnection after
/// the HTTPServer saw `Upgrade: websocket`: sends the 101 handshake, then
/// runs a frame loop that answers pings, reassembles fragmented text
/// messages, routes every finished message through the APIRouter, and
/// answers a client close. Events do not enter through here — the hub
/// pushes them with `send(json:)`.
///
/// MainActor by confinement: the Network callbacks only hop their bytes into
/// `buffer` on the main actor, and every other entry point (`send`, `close`)
/// is called from the hub, which is MainActor too.
@MainActor
final class WSSession {
    private let connection: NWConnection
    private let router: APIRouter
    private weak var hub: WSEventHub?
    private var buffer = Data()
    private var closed = false
    /// Payload bytes of the message being accumulated across fragments.
    private var messageData = Data()
    /// Opcode of the fragmented message in progress; nil when none is open.
    private var fragmentOpcode: UInt8?

    /// Whether the session is already torn down. The hub consults it in
    /// `register`, so a handshake it rejected is never added to the fan-out.
    var isClosed: Bool { closed }

    /// Takes over an already-accepted connection whose head requested the
    /// upgrade. Sends the 101 handshake, then `start()` runs the frame loop.
    init(connection: NWConnection, head: HTTPHead, router: APIRouter, hub: WSEventHub) {
        self.connection = connection
        self.router = router
        self.hub = hub
        // The handshake is written before any frame processing starts; the
        // connection is already owned exclusively by this session.
        guard let key = Self.handshakeKey(head.headers["sec-websocket-key"]) else {
            // Answering with an `accept` derived from garbage would hand the
            // client a handshake it can never verify, so refuse instead — and
            // wait for the refusal to flush before the socket drops.
            reject(Data("{\"error\":\"Sec-WebSocket-Key 缺失或不是合法 base64\"}".utf8))
            return
        }
        sendRaw(WSCodec.upgradeResponse(acceptValue: WSCodec.acceptValue(for: key)))
    }

    /// The request's `Sec-WebSocket-Key`, when it is present and decodes as
    /// base64 of the 16 bytes RFC 6455 §4.2.1 requires of a client.
    private static func handshakeKey(_ header: String?) -> String? {
        guard let header, !header.isEmpty, let decoded = Data(base64Encoded: header) else { return nil }
        return decoded.count == 16 ? header : nil
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state, let self {
                Task { @MainActor in self.finish() }
            }
        }
        receive()
    }

    private func receive() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            Task { @MainActor in
                if let data { self.buffer.append(data) }
                if error != nil || isComplete {
                    self.finish()
                    return
                }
                self.pump()
            }
        }
    }

    private func pump() {
        guard let (frames, remainder) = WSCodec.decode(buffer) else {
            // One signal for every violation the codec sees — unmasked frame,
            // bad length, an oversized per-frame claim — so 1002 it is, even
            // where RFC 6455 would distinguish 1009.
            close(code: 1002)
            return
        }
        buffer = remainder
        for frame in frames {
            switch frame.opcode {
            case 0x1, 0x0:   // a text message, or a continuation of one
                guard ingest(frame) else { return }
            case 0x2:        // binary: this is a text-only server
                close(code: 1003)   // unsupported data (RFC 6455 §7.4.1)
                return
            case 0x9:        // ping → pong with the same payload
                send(data: WSCodec.encode(opcode: 0xA, payload: frame.payload))
            case 0xA:        // a pong we never asked for: nothing to do
                break
            case 0x8:        // close → echo the client's code, then done
                close(with: frame.payload)
                return
            default:         // 0x3–0x7 and 0xB–0xF are reserved by RFC 6455
                close(code: 1002)
                return
            }
        }
        receive()
    }

    /// Accumulates a data frame into the message in progress and dispatches
    /// the message once it is complete. Returns false when the session ended.
    private func ingest(_ frame: WSFrame) -> Bool {
        if frame.opcode == 0x0 {
            // A continuation is only meaningful inside a fragmented message.
            guard fragmentOpcode != nil else {
                close(code: 1002)
                return false
            }
        } else {
            // Opening a second message while one is running would interleave
            // them, which RFC 6455 §5.4 forbids.
            guard fragmentOpcode == nil else {
                close(code: 1002)
                return false
            }
            if !frame.fin { fragmentOpcode = frame.opcode }
        }
        messageData.append(frame.payload)
        // The cap guards the reassembled message, not the frame: `WSCodec`
        // already limits one frame, but 100 continuation frames of 65 KB are
        // individually legal and would still grow this buffer forever.
        guard messageData.count <= WSCodec.maxMessageSize else {
            close(code: 1002)
            return false
        }
        guard frame.fin else { return true }

        // Only 0x1 gets here (binary is refused in `pump`; continuations carry
        // the type of the message they continue).
        let payload = messageData
        messageData = Data()
        fragmentOpcode = nil
        Task { @MainActor [router] in
            let responseData = await router.handleWSCommand(payload)
            send(data: WSCodec.encode(opcode: 0x1, payload: responseData))
        }
        return true
    }

    /// Sends one JSON object as a text frame. Safe to call from the hub.
    func send(json: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: json) else { return }
        send(data: WSCodec.encode(opcode: 0x1, payload: data))
    }

    func send(text: String) {
        send(data: WSCodec.encode(opcode: 0x1, payload: Data(text.utf8)))
    }

    private func send(data: Data) {
        guard !closed else { return }
        sendRaw(data)
    }

    /// Sends bytes and optionally cancels the connection once they are
    /// flushed. Only the `Sendable` connection crosses into the Network
    /// callback; `self` never leaves the main actor.
    private func sendRaw(_ data: Data, cancelAfterSend: Bool = false) {
        let connection = self.connection
        connection.send(content: data, completion: .contentProcessed { _ in
            if cancelAfterSend { connection.cancel() }
        })
    }

    /// Sends a close frame with `code`, then tears the session down once it
    /// has flushed. Closing first stops any further write or read from racing
    /// the goodbye; the frame itself still goes out.
    func close(code: UInt16) {
        close(with: Data([UInt8(code >> 8), UInt8(code & 0xFF)]))
    }

    private func close(with payload: Data) {
        guard !closed else { return }
        closed = true
        hub?.unregister(self)
        sendRaw(WSCodec.encode(opcode: 0x8, payload: payload), cancelAfterSend: true)
    }

    /// Tears down without a goodbye: the client already went away.
    private func finish() {
        guard !closed else { return }
        closed = true
        hub?.unregister(self)
        connection.cancel()
    }

    /// Answers a refused handshake with a plain 400 and drops the connection
    /// once the reply has flushed. Closing the session first keeps the hub
    /// from ever registering it.
    private func reject(_ body: Data) {
        closed = true
        sendRaw(HTTPCodec.response(status: 400, reason: HTTPCodec.reason(for: 400), body: body), cancelAfterSend: true)
    }
}
