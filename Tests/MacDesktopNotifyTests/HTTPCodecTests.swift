import XCTest
@testable import MacDesktopNotify

final class HTTPCodecTests: XCTestCase {
    private func request(_ raw: String) -> Data { Data(raw.utf8) }

    func testParsesCompleteHeadWithBody() {
        let head = "POST /v1/push?ref=x HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: 7\r\n\r\n{\"a\":1}"
        guard case .head(let parsed, let remainder) = HTTPCodec.parseRequestHead(request(head)) else {
            return XCTFail("expected .head")
        }
        XCTAssertEqual(parsed.method, "POST")
        XCTAssertEqual(parsed.path, "/v1/push")
        XCTAssertEqual(parsed.query["ref"], "x")
        XCTAssertEqual(parsed.headers["content-length"], "7")
        XCTAssertEqual(parsed.contentLength, 7)
        XCTAssertEqual(String(decoding: remainder, as: UTF8.self), "{\"a\":1}")
    }

    func testPartialHeadNeedsMoreData() {
        let partial = "GET /v1/status HTTP/1.1\r\nHost: x\r\n"
        guard case .needMoreData = HTTPCodec.parseRequestHead(request(partial)) else {
            return XCTFail("expected .needMoreData")
        }
    }

    func testGarbageIsMalformed() {
        guard case .malformed = HTTPCodec.parseRequestHead(request("hello world\r\n\r\n")) else {
            return XCTFail("expected .malformed")
        }
    }

    /// A request line needs three tokens, the last one an HTTP version.
    func testRequestLineWithoutHTTPVersionIsMalformed() {
        guard case .malformed = HTTPCodec.parseRequestHead(request("GET /v1/status nosuchversion\r\n\r\n")) else {
            return XCTFail("expected .malformed")
        }
    }

    func testOversizedHeadIsMalformed() {
        let big = "GET /v1/status HTTP/1.1\r\nX-Big: " + String(repeating: "a", count: 9000) + "\r\n\r\n"
        guard case .malformed = HTTPCodec.parseRequestHead(request(big)) else {
            return XCTFail("expected .malformed")
        }
    }

    /// A head of exactly `maxHeadLength` bytes parses even when its delimiter
    /// straddles two receives: the buffer then holds the head plus up to 3
    /// delimiter bytes, which must not read as "head over the limit".
    func testHeadAtLimitWithStraddlingDelimiterParses() {
        // The head is everything before the delimiter, so it does not end
        // in CRLF itself.
        let head = "GET /v1/status HTTP/1.1\r\nX-Big: " + String(repeating: "a", count: 8160)
        XCTAssertEqual(head.utf8.count, HTTPCodec.maxHeadLength)

        // First receive ends two bytes into "\r\n\r\n".
        let firstChunk = request(head) + Data("\r\n".utf8)
        XCTAssertEqual(firstChunk.count, HTTPCodec.maxHeadLength + 2)
        guard case .needMoreData = HTTPCodec.parseRequestHead(firstChunk) else {
            return XCTFail("expected .needMoreData for head + partial delimiter")
        }

        let complete = firstChunk + Data("\r\n".utf8)
        guard case .head(let parsed, let remainder) = HTTPCodec.parseRequestHead(complete) else {
            return XCTFail("expected .head once the delimiter completes")
        }
        XCTAssertEqual(parsed.path, "/v1/status")
        XCTAssertEqual(parsed.contentLength, 0)
        XCTAssertTrue(remainder.isEmpty)
    }

    /// No delimiter and genuinely more than `maxHeadLength` head bytes is
    /// still malformed — the straddle tolerance is 3 bytes, not a free pass.
    func testHeadOverLimitWithoutDelimiterIsMalformed() {
        let head = "GET /v1/status HTTP/1.1\r\nX-Big: " + String(repeating: "a", count: 8164)
        XCTAssertGreaterThan(head.utf8.count, HTTPCodec.maxHeadLength + 3)
        guard case .malformed = HTTPCodec.parseRequestHead(request(head)) else {
            return XCTFail("expected .malformed")
        }
    }

    func testMissingContentLengthMeansZero() {
        let head = "GET /v1/status HTTP/1.1\r\nHost: x\r\n\r\n"
        guard case .head(let parsed, _) = HTTPCodec.parseRequestHead(request(head)) else {
            return XCTFail("expected .head")
        }
        XCTAssertEqual(parsed.contentLength, 0)
    }

    func testResponseSerializerEmitsFixedHeaders() {
        let out = String(decoding: HTTPCodec.response(status: 200, reason: "OK", body: Data("{}".utf8)), as: UTF8.self)
        XCTAssertTrue(out.hasPrefix("HTTP/1.1 200 OK\r\n"), out)
        XCTAssertTrue(out.contains("Content-Type: application/json; charset=utf-8\r\n"))
        XCTAssertTrue(out.contains("Connection: close\r\n"))
        XCTAssertTrue(out.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(out.hasSuffix("\r\n\r\n{}"), out)
    }

    func testReasonPhrases() {
        XCTAssertEqual(HTTPCodec.reason(for: 200), "OK")
        XCTAssertEqual(HTTPCodec.reason(for: 400), "Bad Request")
        XCTAssertEqual(HTTPCodec.reason(for: 403), "Forbidden")
        XCTAssertEqual(HTTPCodec.reason(for: 404), "Not Found")
        XCTAssertEqual(HTTPCodec.reason(for: 405), "Method Not Allowed")
        XCTAssertEqual(HTTPCodec.reason(for: 413), "Payload Too Large")
        XCTAssertEqual(HTTPCodec.reason(for: 101), "Switching Protocols")
        XCTAssertEqual(HTTPCodec.reason(for: 418), "Status 418")   // fallback
    }

    // MARK: - Host validation (DNS-rebinding defense)

    /// No Host header at all — curl on a unix socket or an HTTP/1.0 client —
    /// is not a browser and poses no rebinding vector: allow.
    func testAbsentHostIsAllowed() {
        XCTAssertTrue(HTTPCodec.isLocalHost(hostHeader: nil))
        XCTAssertTrue(HTTPCodec.isLocalHost(hostHeader: ""))
    }

    func testLoopbackHostsWithPortsAreAllowed() {
        XCTAssertTrue(HTTPCodec.isLocalHost(hostHeader: "127.0.0.1:4770"))
        XCTAssertTrue(HTTPCodec.isLocalHost(hostHeader: "localhost"))
        XCTAssertTrue(HTTPCodec.isLocalHost(hostHeader: "localhost:4770"))
        XCTAssertTrue(HTTPCodec.isLocalHost(hostHeader: "[::1]:4770"))
    }

    /// Host is case-insensitive per RFC 7230 §5.4.
    func testLocalhostIsMatchedCaseInsensitively() {
        XCTAssertTrue(HTTPCodec.isLocalHost(hostHeader: "LOCALHOST"))
        XCTAssertTrue(HTTPCodec.isLocalHost(hostHeader: "LocalHost:4770"))
    }

    func testForeignHostIsRejected() {
        XCTAssertFalse(HTTPCodec.isLocalHost(hostHeader: "evil.example.com"))
        XCTAssertFalse(HTTPCodec.isLocalHost(hostHeader: "evil.example.com:4770"))
    }

    /// The match must be exact: a suffix that merely ends in an allowed name
    /// is a different host.
    func testSuffixLookalikeHostsAreRejected() {
        XCTAssertFalse(HTTPCodec.isLocalHost(hostHeader: "sub.localhost.evil.com"))
        XCTAssertFalse(HTTPCodec.isLocalHost(hostHeader: "127.0.0.1.evil.com"))
        XCTAssertFalse(HTTPCodec.isLocalHost(hostHeader: "localhost.evil.com"))
        XCTAssertFalse(HTTPCodec.isLocalHost(hostHeader: "notlocalhost"))
    }

    // MARK: - Origin validation (drive-by browser defense)

    func testLocalOriginsAreAllowed() {
        for origin in [
            "http://127.0.0.1", "http://localhost",
            "https://127.0.0.1", "https://localhost",
            "ws://127.0.0.1", "ws://localhost",
            "file://",
        ] {
            XCTAssertTrue(HTTPCodec.isAllowedOrigin(origin), origin)
        }
    }

    /// A port on an otherwise-local origin is a different origin: reject.
    func testLocalOriginWithForeignPortIsRejected() {
        XCTAssertFalse(HTTPCodec.isAllowedOrigin("http://127.0.0.1:8080"))
        XCTAssertFalse(HTTPCodec.isAllowedOrigin("http://localhost:4770"))
    }

    func testForeignOriginsAreRejected() {
        XCTAssertFalse(HTTPCodec.isAllowedOrigin("http://evil.example.com"))
        XCTAssertFalse(HTTPCodec.isAllowedOrigin("https://sub.localhost.evil.com"))
        XCTAssertFalse(HTTPCodec.isAllowedOrigin("ws://evil.example.com"))
        // Case variation of a local origin is still local.
        XCTAssertTrue(HTTPCodec.isAllowedOrigin("HTTP://LocalHost"))
    }
}
