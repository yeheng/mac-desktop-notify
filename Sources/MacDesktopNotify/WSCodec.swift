import Foundation
import CryptoKit

struct WSFrame: Equatable {
    let fin: Bool
    let opcode: UInt8
    let payload: Data
}

/// RFC 6455 minus what this server never needs: no extensions, no
/// compression, text and control frames only, one message size cap.
enum WSCodec {
    static let websocketGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
    static let maxMessageSize = 65536

    static func acceptValue(for key: String) -> String {
        let digest = Insecure.SHA1.hash(data: Data((key + websocketGUID).utf8))
        return Data(digest).base64EncodedString()
    }

    static func upgradeResponse(acceptValue: String) -> Data {
        // Same single-string rule as HTTPCodec.response: the handshake head is
        // fixed-shape, so build it in one interpolation instead of fragment
        // `Data` appends.
        let head = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(acceptValue)\r\n\r\n"
        return Data(head.utf8)
    }

    static func decode(_ data: Data) -> (frames: [WSFrame], remainder: Data)? {
        let bytes = [UInt8](data)      // one conversion per receive, not per frame
        var frames: [WSFrame] = []
        var cursor = 0
        while cursor < bytes.count {
            switch decodeOne(bytes, from: cursor) {
            case .violation:
                return nil
            case .needMoreData:
                return (frames, Data(bytes[cursor...]))
            case .frame(let frame, let next):
                frames.append(frame)
                cursor = next
            }
        }
        return (frames, Data())
    }

    /// Three outcomes, one enum: the same shape `HTTPCodec.parseRequestHead`
    /// uses. The old `??` return encoded "violation" and "need more bytes" as
    /// two kinds of nil and forced a guard/if-let double jump at the call site.
    private enum DecodeStep {
        case violation
        case needMoreData
        case frame(WSFrame, Int)
    }

    /// Decodes the frame starting at `start`, returning the index just past it.
    /// `bytes` is the whole receive buffer, converted once by `decode`: the old
    /// per-frame `[UInt8](data)` + `Data(bytes[offset...])` pair copied the
    /// entire remainder twice per frame, which is O(n²) on a buffered burst.
    private static func decodeOne(_ bytes: [UInt8], from start: Int) -> DecodeStep {
        guard bytes.count - start >= 2 else { return .needMoreData }

        let fin = bytes[start] & 0x80 != 0
        let opcode = bytes[start] & 0x0F
        let masked = bytes[start + 1] & 0x80 != 0
        var length = Int(bytes[start + 1] & 0x7F)
        var offset = start + 2

        // Client→server frames MUST be masked (RFC 6455 §5.1).
        guard masked else { return .violation }

        switch length {
        case 126:
            guard bytes.count >= offset + 2 else { return .needMoreData }
            length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
        case 127:
            guard bytes.count >= offset + 8 else { return .needMoreData }
            var value = 0
            for i in 0..<8 { value = value << 8 | Int(bytes[offset + i]) }
            guard value >= 0, value <= maxMessageSize else { return .violation }
            length = value
            offset += 8
        default:
            break
        }
        guard length <= maxMessageSize else { return .violation }

        // Control frames must not be fragmented and stay ≤ 125 bytes.
        if opcode >= 0x8, (!fin || length > 125) { return .violation }

        guard bytes.count >= offset + 4 + length else { return .needMoreData }
        let mask = [bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]]
        offset += 4
        // One contiguous buffer, XORed in place: no intermediate Array from a
        // high-order `.map`, no per-byte closure dispatch — allocation stays
        // O(1) regardless of frame size.
        var payload = Data(bytes[offset..<(offset + length)])
        for i in 0..<length {
            payload[i] ^= mask[i & 3]
        }
        return .frame(WSFrame(fin: fin, opcode: opcode, payload: payload), offset + length)
    }

    static func encode(opcode: UInt8, payload: Data) -> Data {
        var out = Data([0x80 | opcode])   // FIN always set; server frames unmasked
        let length = payload.count
        if length < 126 {
            out.append(UInt8(length))
        } else if length <= 0xFFFF {
            out.append(126)
            out.append(UInt8(length >> 8))
            out.append(UInt8(length & 0xFF))
        } else {
            out.append(127)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((length >> shift) & 0xFF))
            }
        }
        out.append(payload)
        return out
    }
}
