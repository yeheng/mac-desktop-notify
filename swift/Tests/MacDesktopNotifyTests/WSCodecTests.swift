import XCTest
import CryptoKit
@testable import MacDesktopNotify

final class WSCodecTests: XCTestCase {
    /// `encode` emits server→client frames, which are never masked, while
    /// `decode` only accepts client→server frames, which always are. Applying
    /// a mask here stands in for the real client so round-trip tests can feed
    /// an encoded frame back through `decode`.
    private func clientMasked(_ frame: Data, mask: [UInt8] = [0x37, 0xfa, 0x21, 0x3d]) -> Data {
        var bytes = [UInt8](frame)
        let length = Int(bytes[1] & 0x7F)
        let payloadStart = 2 + (length == 126 ? 2 : length == 127 ? 8 : 0)
        bytes[1] |= 0x80
        for i in payloadStart..<bytes.count { bytes[i] ^= mask[(i - payloadStart) % 4] }
        bytes.insert(contentsOf: mask, at: payloadStart)
        return Data(bytes)
    }

    func testAcceptValueMatchesRFC6455() {
        // RFC 6455 §1.3 worked example: this exact key/accept pair.
        XCTAssertEqual(
            WSCodec.acceptValue(for: "dGhlIHNhbXBsZSBub25jZQ=="),
            "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        )
    }

    func testUpgradeResponseHasRequiredHeaders() {
        let text = String(decoding: WSCodec.upgradeResponse(acceptValue: "abc"), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 101 Switching Protocols\r\n"))
        XCTAssertTrue(text.contains("Upgrade: websocket\r\n"))
        XCTAssertTrue(text.contains("Connection: Upgrade\r\n"))
        XCTAssertTrue(text.contains("Sec-WebSocket-Accept: abc\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
    }

    func testEncodesUnmaskedTextFrame() {
        let frame = WSCodec.encode(opcode: 0x1, payload: Data("hello".utf8))
        // FIN=1, opcode=1 → 0x81; server frames unmasked → mask bit 0; len 5.
        XCTAssertEqual([UInt8](frame), [0x81, 0x05] + Array("hello".utf8))
    }

    func testDecodesMaskedClientFrame() throws {
        // Client frame: FIN|text, mask bit set, length 5, mask, masked "Hello".
        let mask: [UInt8] = [0x37, 0xfa, 0x21, 0x3d]
        let plain = Array("Hello".utf8)
        let masked = plain.enumerated().map { $0.element ^ mask[$0.offset % 4] }
        let frame: [UInt8] = [0x81, 0x85] + mask + masked
        let (frames, remainder) = try XCTUnwrap(WSCodec.decode(Data(frame)))
        XCTAssertEqual(frames, [WSFrame(fin: true, opcode: 0x1, payload: Data("Hello".utf8))])
        XCTAssertTrue(remainder.isEmpty)
    }

    func testDecodesTwoFramesAndKeepsRemainder() throws {
        let one = clientMasked(WSCodec.encode(opcode: 0x9, payload: Data()))
        var twoFrames = one + one
        twoFrames.append(Data([0x81]))   // start of a third, incomplete frame
        let (frames, remainder) = try XCTUnwrap(WSCodec.decode(twoFrames))
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].opcode, 0x9)
        XCTAssertEqual(remainder, Data([0x81]))
    }

    func testHandles16BitAnd64BitLengths() throws {
        let big = Data(repeating: 0x61, count: 70_000)   // 64-bit length (> 65535 but > maxMessageSize)
        XCTAssertNil(WSCodec.decode(clientMasked(WSCodec.encode(opcode: 0x1, payload: big))),
                     "messages over maxMessageSize are a protocol violation for this server")

        let medium = Data(repeating: 0x62, count: 300)   // 16-bit length
        let (frames, _) = try XCTUnwrap(WSCodec.decode(clientMasked(WSCodec.encode(opcode: 0x1, payload: medium))))
        XCTAssertEqual(frames.first?.payload, medium)

        // Exactly at the cap the 64-bit length form is legal, not a violation.
        let atCap = Data(repeating: 0x63, count: 65_536)
        let (capped, _) = try XCTUnwrap(WSCodec.decode(clientMasked(WSCodec.encode(opcode: 0x1, payload: atCap))))
        XCTAssertEqual(capped.first?.payload, atCap)
    }

    func testMaskedServerFrameFromClientIsRejected() {
        // Server→client frames must be unmasked; a client sending a masked
        // frame is CORRECT — but a client frame WITHOUT mask is a violation.
        // Here: unmasked client frame (mask bit 0) must decode-fail.
        let frame: [UInt8] = [0x81, 0x05] + Array("hello".utf8)
        XCTAssertNil(WSCodec.decode(Data(frame)), "client frames must be masked")
    }

    /// 一帧缓冲里塞满小帧：每帧都要正确解出。
    /// 旧实现每帧把整个剩余 buffer 转成 [UInt8] 再拷回 Data，代价 O(n²)；
    /// 本用例钉住功能不变，让那次重构可以安全进行。
    func testDecodesManyFramesInOneBuffer() throws {
        let one = clientMasked(WSCodec.encode(opcode: 0x9, payload: Data("ping".utf8)))
        var buffer = Data()
        for _ in 0..<500 { buffer.append(one) }

        let (frames, remainder) = try XCTUnwrap(WSCodec.decode(buffer))
        XCTAssertEqual(frames.count, 500)
        XCTAssertTrue(frames.allSatisfy { $0.opcode == 0x9 && $0.payload == Data("ping".utf8) })
        XCTAssertTrue(remainder.isEmpty)
    }

    /// 空输入与"刚好一整帧"的边界：游标不能越界，remainder 必须是空。
    func testEmptyAndExactBuffers() throws {
        let (empty, emptyRemainder) = try XCTUnwrap(WSCodec.decode(Data()))
        XCTAssertTrue(empty.isEmpty)
        XCTAssertTrue(emptyRemainder.isEmpty)

        let exact = clientMasked(WSCodec.encode(opcode: 0x1, payload: Data("x".utf8)))
        let (frames, remainder) = try XCTUnwrap(WSCodec.decode(exact))
        XCTAssertEqual(frames.count, 1)
        XCTAssertTrue(remainder.isEmpty)
    }
}
