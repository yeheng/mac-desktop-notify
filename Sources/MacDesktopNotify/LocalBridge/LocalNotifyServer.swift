import Foundation
import UnixSocketSupport

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

            // Path length is validated inside makeUnixSocketAddress (throws pathTooLong).
            self.serverSocket = try createUnixStreamSocket()

            var addr = try makeUnixSocketAddress(path: self.socketPath)

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
                let client = Darwin.accept(self.serverSocket, nil, nil)
                guard client >= 0 else {
                    if errno == EINTR { continue }
                    break
                }
                // 必须在独立并发队列处理客户端；串行 socketQueue 正忙于 accept 循环。
                self.clientQueue.async { [weak self] in
                    guard let self else { return }
                    self.handleClient(client)
                    Darwin.close(client)
                }
            }
        }
    }

    private func handleClient(_ clientSocket: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        let bytesRead = Darwin.read(clientSocket, &buffer, buffer.count)
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
        _ = sendResponse(to: clientSocket, success: true, message: "OK", id: record.id)
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
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)

    var description: String {
        switch self {
        case .bindFailed(let errno):
            return "Bind failed: \(String(cString: strerror(errno)))"
        case .listenFailed(let errno):
            return "Listen failed: \(String(cString: strerror(errno)))"
        }
    }
}
