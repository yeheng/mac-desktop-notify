import Foundation
import Network
import Observation

/// Owns the two listeners and their lifecycle. Settings are read on every
/// `restart()`, which is idempotent: stopping first means a port change or
/// a toggle is just "restart with the new parameters".
@MainActor
@Observable
final class APIListenerService {
    /// The app's one service instance. AppDelegate and SettingsView both use it.
    static let shared = APIListenerService()

    static var defaultSocketPath: String {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base.appendingPathComponent("MacDesktopNotify", isDirectory: true)
                    .appendingPathComponent("api.sock").path
    }

    /// Nil when the HTTP listener is healthy or off; a human-readable reason
    /// when it failed to bind (shown in Settings).
    private(set) var httpError: String?
    /// Nil when the socket listener is healthy or off; set when the stale
    /// file could not be removed or the bind failed (shown in Settings).
    private(set) var socketError: String?
    private(set) var isHttpListening = false
    private(set) var isSocketListening = false

    private let socketPath: String
    private var httpServer: HTTPServer?
    private var socketServer: HTTPServer?
    private let hub = WSEventHub(manager: .shared)

    init(socketPath: String = APIListenerService.defaultSocketPath) {
        self.socketPath = socketPath
    }

    func restart() {
        stop()
        let settings = AppSettings.shared
        let router = APIRouter(manager: .shared, listening: { [weak self] in
            (unixSocket: self?.isSocketListening ?? false, http: self?.isHttpListening ?? false)
        })

        if settings.apiUnixSocketEnabled {
            startSocket(router: router)
        }
        if settings.apiHttpEnabled {
            startHTTP(router: router, port: UInt16(clamping: settings.apiHttpPort))
        }
    }

    func stop() {
        httpServer?.stop()
        httpServer = nil
        httpError = nil
        isHttpListening = false
        socketServer?.stop()
        socketServer = nil
        socketError = nil
        isSocketListening = false
    }

    private func installUpgrade(on server: HTTPServer, router: APIRouter) {
        server.onUpgrade = { head, connection in
            guard head.path == "/v1/events" else { return false }
            let session = WSSession(connection: connection, head: head, router: router, hub: self.hub)
            self.hub.register(session)
            session.start()
            return true
        }
    }

    private func startHTTP(router: APIRouter, port: UInt16) {
        // A nil server means NWListener rejected the parameters outright,
        // before any port was touched — report and stay off like every other
        // listener failure, instead of the old `try!` crash at construction.
        guard let server = HTTPServer(parameters: HTTPServerTransport.localhostTCP(port: port), router: { request in
            await router.handle(request)
        }) else {
            isHttpListening = false
            httpError = "无法创建 HTTP 监听器"
            return
        }
        installUpgrade(on: server, router: router)
        httpServer = server
        Task {
            do {
                _ = try await server.start()
                // A restart while this start was in flight cancelled the
                // listener; the server that replaced it owns the flags now.
                guard httpServer === server else { return }
                isHttpListening = true
                httpError = nil
            } catch {
                guard httpServer === server else { return }
                isHttpListening = false
                httpError = "端口 \(port) 无法监听"
            }
        }
    }

    private func startSocket(router: APIRouter) {
        // A socket file left by a previous run blocks the bind; the
        // listener below is dead by definition, so the file is garbage.
        // An occupier we cannot remove (a directory, permissions) means the
        // transport cannot come up at all: report and stay off.
        if FileManager.default.fileExists(atPath: socketPath) {
            do {
                try FileManager.default.removeItem(atPath: socketPath)
            } catch {
                socketError = "旧 socket 文件无法移除：\(error.localizedDescription)"
                isSocketListening = false
                return
            }
        }
        try? FileManager.default.createDirectory(
            atPath: (socketPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        guard let server = HTTPServer(parameters: HTTPServerTransport.unixSocket(path: socketPath), router: { request in
            await router.handle(request)
        }) else {
            isSocketListening = false
            socketError = "无法创建 Unix socket 监听器"
            return
        }
        installUpgrade(on: server, router: router)
        socketServer = server
        Task {
            do {
                _ = try await server.start()
                guard socketServer === server else { return }
                // NWListener has no permission parameter; tighten the file
                // the kernel just created for us. Between `.ready` and this
                // chmod the file sits at the process umask's default (usually
                // 0644 for other-local users): an accepted window — this is a
                // single-user machine and the gap is milliseconds wide.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: socketPath
                )
                isSocketListening = true
                socketError = nil
            } catch {
                guard socketServer === server else { return }
                isSocketListening = false
                socketError = "Unix socket 无法监听"
            }
        }
    }
}
