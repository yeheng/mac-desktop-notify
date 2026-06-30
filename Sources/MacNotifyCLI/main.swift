import Foundation

/// 本地命令行工具，通过 Unix socket 向 MacDesktopNotify 发送通知。
struct MacNotifyCLI {
    static let socketPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".mac-desktop-notify/bridge.sock")
        .path

    static func main() async {
        let args = CommandLine.arguments.dropFirst()

        guard args.count >= 2 else {
            printUsage()
            exit(1)
        }

        var iterator = args.makeIterator()
        let title = iterator.next()!
        let body = iterator.next()!

        var type = "info"
        var timeout: TimeInterval? = nil

        while let arg = iterator.next() {
            switch arg {
            case "--type":
                type = iterator.next() ?? "info"
            case "--timeout":
                if let value = iterator.next(), let t = TimeInterval(value) {
                    timeout = t
                }
            default:
                break
            }
        }

        let request: [String: Any] = [
            "title": title,
            "body": body,
            "type": type,
            "timeout": timeout ?? 8
        ]

        do {
            let response = try await send(request: request)
            print(response)
        } catch {
            print("Error: \(error)")
            exit(1)
        }
    }

    private static func send(request: [String: Any]) async throws -> String {
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else {
            throw CLIError.socketFailed
        }
        defer { Darwin.close(socket) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path) - 1
        socketPath.withCString { cString in
            withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                strncpy(
                    baseAddress.assumingMemoryBound(to: CChar.self),
                    cString,
                    pathSize
                )
            }
        }

        let connected = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(socket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw CLIError.connectionFailed(errno: errno)
        }

        guard let data = try? JSONSerialization.data(withJSONObject: request, options: []),
              let line = String(data: data, encoding: .utf8) else {
            throw CLIError.encodingFailed
        }
        let payload = line + "\n"
        _ = payload.withCString { Darwin.send(socket, $0, strlen($0), 0) }

        // 发送 FIN，让服务端 read 返回
        Darwin.shutdown(socket, Int32(SHUT_WR))

        // 读取响应
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = Darwin.read(socket, &buffer, buffer.count)
        guard bytesRead > 0 else {
            throw CLIError.noResponse
        }
        return String(bytes: buffer.prefix(bytesRead), encoding: .utf8) ?? ""
    }

    private static func printUsage() {
        print("Usage: mac-notify <title> <body> [--type info|success|warning|error] [--timeout seconds]")
    }
}

enum CLIError: Error, CustomStringConvertible {
    case socketFailed
    case connectionFailed(errno: Int32)
    case encodingFailed
    case noResponse

    var description: String {
        switch self {
        case .socketFailed:
            return "Failed to create socket"
        case .connectionFailed(let errno):
            return "Failed to connect to MacDesktopNotify: \(String(cString: strerror(errno)))"
        case .encodingFailed:
            return "Failed to encode request"
        case .noResponse:
            return "No response from MacDesktopNotify"
        }
    }
}

@main
struct Main {
    static func main() async {
        await MacNotifyCLI.main()
    }
}
