import Foundation

/// 本地 Unix domain socket 通知桥。
/// 接收 newline-delimited JSON，字段同 `NotifyCreateRequest`，转发给 `NotifyManager`。
/// 注意：此类刻意不标记为 @MainActor，所有 socket I/O 在后台线程执行，
/// 仅在访问主线程的 `NotifyManager` 时切换。
final class LocalNotifyServer {
    private let manager: NotifyManager
    private let socketPath: String
    private let socketQueue = DispatchQueue(label: "com.macdesktopnotify.local-server", qos: .utility)
    private let clientQueue = DispatchQueue(label: "com.macdesktopnotify.local-client", qos: .utility, attributes: .concurrent)
    private var serverSocket: Int32 = -1
    private var isStopped = false
    private let decoder = JSONDecoder()

    init(manager: NotifyManager, socketPath: String? = nil) {
        self.manager = manager
        self.socketPath = socketPath ?? LocalNotifyServer.defaultSocketPath
    }

    static var defaultSocketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mac-desktop-notify")
            .appendingPathComponent("bridge.sock")
            .path
    }

    var isRunning: Bool { serverSocket >= 0 }

    func start() throws {
        try socketQueue.sync { [weak self] in
            guard let self else { return }
            guard self.serverSocket < 0 else { return }

            let directory = (self.socketPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(
                atPath: directory,
                withIntermediateDirectories: true,
                attributes: nil
            )

            if FileManager.default.fileExists(atPath: self.socketPath) {
                try FileManager.default.removeItem(atPath: self.socketPath)
            }

            self.serverSocket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard self.serverSocket >= 0 else {
                throw LocalNotifyError.socketCreationFailed(errno: errno)
            }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let pathSize = MemoryLayout.size(ofValue: addr.sun_path) - 1
            self.socketPath.withCString { cString in
                withUnsafeMutableBytes(of: &addr.sun_path) { rawBuffer in
                    guard let baseAddress = rawBuffer.baseAddress else { return }
                    strncpy(
                        baseAddress.assumingMemoryBound(to: CChar.self),
                        cString,
                        pathSize
                    )
                }
            }

            let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.bind(self.serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bindResult == 0 else {
                let err = errno
                Darwin.close(self.serverSocket)
                self.serverSocket = -1
                throw LocalNotifyError.bindFailed(errno: err)
            }

            guard Darwin.listen(self.serverSocket, 5) == 0 else {
                let err = errno
                Darwin.close(self.serverSocket)
                self.serverSocket = -1
                throw LocalNotifyError.listenFailed(errno: err)
            }

            self.isStopped = false
            let log = "[LocalNotifyServer] listening on \(self.socketPath)\n"
            try? log.write(toFile: "/tmp/mdn-server.log", atomically: true, encoding: .utf8)
            self.acceptLoop()
        }
    }

    func stop() {
        isStopped = true
        if serverSocket >= 0 {
            let sock = serverSocket
            serverSocket = -1
            Darwin.close(sock)
        }
        try? FileManager.default.removeItem(atPath: socketPath)
    }

    private func acceptLoop() {
        socketQueue.async { [weak self] in
            guard let self else { return }
            while !self.isStopped {
                self.appendLog("waiting for accept")
                let client = Darwin.accept(self.serverSocket, nil, nil)
                self.appendLog("accept returned \(client), errno=\(errno)")
                guard client >= 0 else {
                    if errno == EINTR { continue }
                    break
                }
                // 必须在独立并发队列处理客户端；串行 socketQueue 正忙于 accept 循环。
                self.clientQueue.async { [weak self] in
                    guard let self else { return }
                    self.appendLog("handling client \(client)")
                    self.handleClient(client)
                    Darwin.close(client)
                }
            }
        }
    }

    private func handleClient(_ clientSocket: Int32) {
        appendLog("reading from client \(clientSocket)")
        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = Darwin.read(clientSocket, &buffer, buffer.count)
        appendLog("read \(bytesRead) bytes")
        guard bytesRead > 0 else {
            _ = sendResponse(to: clientSocket, success: false, message: "Failed to read request")
            return
        }

        let data = Data(buffer.prefix(bytesRead))
        guard let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !line.isEmpty else {
            _ = sendResponse(to: clientSocket, success: false, message: "Empty request")
            return
        }

        guard let requestData = line.data(using: .utf8),
              let request = try? decoder.decode(NotifyCreateRequest.self, from: requestData) else {
            _ = sendResponse(to: clientSocket, success: false, message: "Invalid JSON or request format")
            return
        }

        if let validationError = request.validate() {
            _ = sendResponse(to: clientSocket, success: false, message: validationError.rawValue)
            return
        }

        let record = NotificationRecord(request: request)
        if let error = record.validationError {
            _ = sendResponse(to: clientSocket, success: false, message: error)
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.manager.add(record)
        }
        appendLog("sending OK response")
        let sent = sendResponse(to: clientSocket, success: true, message: "OK", id: record.id)
        appendLog("response sent: \(sent)")
    }

    private func appendLog(_ message: String) {
        let line = "[LocalNotifyServer] \(message)\n"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: "/tmp/mdn-server.log"),
               let handle = FileHandle(forWritingAtPath: "/tmp/mdn-server.log") {
                _ = handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                try? line.write(toFile: "/tmp/mdn-server.log", atomically: true, encoding: .utf8)
            }
        }
    }

    @discardableResult
    private func sendResponse(to socket: Int32, success: Bool, message: String, id: UUID? = nil) -> Bool {
        var payload: [String: Any] = [
            "success": success,
            "message": message
        ]
        if let id {
            payload["id"] = id.uuidString
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
              let string = String(data: data, encoding: .utf8) else {
            return false
        }
        let line = string + "\n"
        return line.withCString { ptr in
            Darwin.send(socket, ptr, strlen(ptr), 0) >= 0
        }
    }
}

enum LocalNotifyError: Error, CustomStringConvertible {
    case socketCreationFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)

    var description: String {
        switch self {
        case .socketCreationFailed(let errno):
            return "Socket creation failed: \(String(cString: strerror(errno)))"
        case .bindFailed(let errno):
            return "Bind failed: \(String(cString: strerror(errno)))"
        case .listenFailed(let errno):
            return "Listen failed: \(String(cString: strerror(errno)))"
        }
    }
}
