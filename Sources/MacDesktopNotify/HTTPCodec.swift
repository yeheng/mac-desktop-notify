import Foundation

/// A parsed HTTP/1.1 request head. This server speaks a fixed, tiny subset:
/// fixed endpoints, `Content-Length` bodies only, no keep-alive.
struct HTTPHead {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let contentLength: Int
}

enum HTTPHeadResult {
    case needMoreData
    case malformed
    case head(HTTPHead, Data)
}

enum HTTPCodec {
    static let maxHeadLength = 8192
    static let maxBodyLength = 32768

    static func parseRequestHead(_ data: Data) -> HTTPHeadResult {
        let delimiter = Data("\r\n\r\n".utf8)
        guard let headRange = data.range(of: delimiter) else {
            // Up to 3 delimiter bytes may already be buffered without the
            // delimiter matching, so the head itself can still be at the limit.
            return data.count > maxHeadLength + 3 ? .malformed : .needMoreData
        }
        let headData = data[data.startIndex..<headRange.lowerBound]
        let remainder = data[headRange.upperBound...]
        guard headData.count <= maxHeadLength else { return .malformed }

        let headText = String(decoding: headData, as: UTF8.self)
        var lines = headText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .malformed }
        lines.removeFirst()

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        // A request line is `METHOD SP target SP HTTP-version`; anything
        // shorter, or without an `HTTP/` version token, is not HTTP/1.1.
        guard parts.count >= 3, parts[2].hasPrefix("HTTP/") else { return .malformed }
        let method = parts[0].uppercased()
        let target = String(parts[1])

        // Split path from query string, percent-decoding each query pair.
        var path = target
        var query: [String: String] = [:]
        if let qIndex = target.firstIndex(of: "?") {
            path = String(target[..<qIndex])
            let queryString = String(target[target.index(after: qIndex)...])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard let key = String(kv[0]).removingPercentEncoding else { continue }
                let value = kv.count > 1 ? String(kv[1]) : ""
                query[key] = value.removingPercentEncoding ?? value
            }
        }

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { return .malformed }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }

        // A negative Content-Length is malformed. An unparseable one is treated
        // as absent (0 — bodyless); an oversized one is NOT malformed — the
        // server answers 413 and closes (spec §8).
        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        guard contentLength >= 0 else { return .malformed }

        return .head(
            HTTPHead(method: method, path: path, query: query, headers: headers, contentLength: contentLength),
            Data(remainder)
        )
    }

    static func response(status: Int, reason: String, body: Data) -> Data {
        var out = Data("HTTP/1.1 \(status) \(reason)\r\n".utf8)
        out.append(Data("Content-Type: application/json; charset=utf-8\r\n".utf8))
        out.append(Data("Content-Length: \(body.count)\r\n".utf8))
        out.append(Data("Connection: close\r\n".utf8))
        out.append(Data("\r\n".utf8))
        out.append(body)
        return out
    }

    static func reason(for status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 101: "Switching Protocols"
        default: "Status \(status)"
        }
    }

    // MARK: Origin checks (DNS-rebinding / drive-by browser defense)

    /// Whether a Host header names this machine. Absent means a non-browser
    /// client (curl on a unix socket, HTTP/1.0 style) and is allowed; anything
    /// but the exact loopback names is not — the check is what turns "bound to
    /// 127.0.0.1" into "not reachable through a rebindable hostname".
    ///
    /// The port suffix is stripped; brackets stay for IPv6 (`[::1]:4770` →
    /// `[::1]`). Comparison is case-insensitive (RFC 7230 §5.4).
    static func isLocalHost(hostHeader: String?) -> Bool {
        guard let hostHeader, !hostHeader.isEmpty else { return true }
        var host = hostHeader.lowercased()
        if host.hasPrefix("[") {
            if let close = host.firstIndex(of: "]") {
                host = String(host[host.startIndex...close])
            }
        } else if let colon = host.firstIndex(of: ":") {
            host = String(host[..<colon])
        }
        return host == "127.0.0.1" || host == "localhost" || host == "[::1]"
    }

    /// Whether an `Origin` header may upgrade to a WebSocket. Browsers attach
    /// it to every cross-origin request and forbid forging it, so a value
    /// outside this set is a web page poking at the local port. Local HTML
    /// dashboards run from `file://`, hence its presence in the set.
    /// Non-browser clients send no Origin at all and never reach this check.
    static func isAllowedOrigin(_ origin: String) -> Bool {
        switch origin.lowercased() {
        case "http://127.0.0.1", "http://localhost",
             "https://127.0.0.1", "https://localhost",
             "ws://127.0.0.1", "ws://localhost",
             "file://":
            true
        default:
            false
        }
    }
}
