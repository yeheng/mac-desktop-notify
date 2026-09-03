import XCTest
@testable import MacDesktopNotify

/// Notification-counting helper safe to mutate from an observer closure.
/// `Sendable` by confinement — `lock` guards the only mutable state.
private final class NotificationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }

    func bump() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        count = 0
    }
}

@MainActor
final class APIListenerServiceTests: SettingsIsolatedTestCase {
    private var tempSocketPath: String {
        NSTemporaryDirectory() + "mdn-svc-\(UUID().uuidString).sock"
    }

    /// `restart()` kicks off listener tasks whose flags flip only once
    /// NWListener reports ready, so assertions poll instead of assuming the
    /// bind already happened. Must await (not block): the flags are set by
    /// main-actor tasks, which a blocking wait would starve.
    private func waitUntil(
        timeout: TimeInterval = 5, _ message: @autoclosure () -> String = "",
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    /// `AppSettings.shared` is a process-wide singleton; pinning all three
    /// keys keeps each test independent of whatever ran before it.
    private func pinAPI(unixSocket: Bool, http: Bool, port: Int) {
        let settings = AppSettings.shared
        settings.apiUnixSocketEnabled = unixSocket
        settings.apiHttpEnabled = http
        settings.apiHttpPort = port
    }

    func testUnixSocketOnByDefaultAndBinds() async throws {
        pinAPI(unixSocket: true, http: false, port: 4770)
        let path = tempSocketPath
        let service = APIListenerService(socketPath: path)
        defer { service.stop() }
        service.restart()
        // Binding is verified by the file existing with 0600 permissions.
        let bound = await waitUntil("socket listener never came up") { service.isSocketListening }
        XCTAssertTrue(bound)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual((attributes[.posixPermissions] as? Int), 0o600)
        XCTAssertFalse(service.isHttpListening, "HTTP is off by default")
    }

    func testStaleSocketFileIsReplaced() async throws {
        pinAPI(unixSocket: true, http: false, port: 4770)
        let path = tempSocketPath
        try Data("stale".utf8).write(to: URL(fileURLWithPath: path))
        let service = APIListenerService(socketPath: path)
        defer { service.stop() }
        service.restart()
        let bound = await waitUntil("a leftover file must not block binding") { service.isSocketListening }
        XCTAssertTrue(bound)
    }

    func testEnableHTTPBindsAndReports() async throws {
        pinAPI(unixSocket: true, http: true, port: 0)   // ephemeral, avoids conflicts in CI
        let service = APIListenerService(socketPath: tempSocketPath)
        defer { service.stop() }
        service.restart()
        let bound = await waitUntil { service.isHttpListening }
        XCTAssertTrue(bound)
        XCTAssertNil(service.httpError)
    }

    func testDisableStopsListeners() async throws {
        pinAPI(unixSocket: false, http: false, port: 4770)
        let service = APIListenerService(socketPath: tempSocketPath)
        defer { service.stop() }
        service.restart()
        XCTAssertFalse(service.isSocketListening)
        XCTAssertFalse(service.isHttpListening)
    }

    /// A path occupied by something that cannot be removed as a stale socket
    /// file must disable the transport AND say why — "off" and "failed" are
    /// different states in the pane. The occupier carries the immutable flag
    /// because its removal fails for any user (kernel-enforced), unlike
    /// permission bits, which the test runner may bypass.
    func testSocketRemovalFailureReportsError() async throws {
        pinAPI(unixSocket: true, http: false, port: 4770)
        let path = tempSocketPath
        try Data("stale".utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: path)
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: path)
            try? FileManager.default.removeItem(atPath: path)
        }
        let service = APIListenerService(socketPath: path)
        defer { service.stop() }
        service.restart()
        XCTAssertNotNil(service.socketError, "an unremovable occupier must surface an error")
        XCTAssertFalse(service.isSocketListening)
    }

    /// The bind-failure branch of `startSocket` (catch → `socketError`) cannot
    /// be forced from the xctest process: NWListener there reports `.ready`
    /// for a unix endpoint without creating the socket file (verified with a
    /// path whose parent is a regular file — ENOTDIR for any real bind, yet
    /// `isSocketListening == true` and no file on disk), and permission-bit
    /// tricks are likewise bypassed. The removal-failure test above covers
    /// the shared "disable the transport AND report" contract.

    /// Assigning the same value (as TextField(value:format:) does on every
    /// keystroke) must not rebind the listeners; a real change must.
    func testUnchangedSettingDoesNotNotify() async throws {
        let counter = NotificationCounter()
        let observer = NotificationCenter.default.addObserver(
            forName: AppSettings.apiSettingsDidChange, object: nil, queue: .main
        ) { _ in counter.bump() }
        defer { NotificationCenter.default.removeObserver(observer) }
        AppSettings.shared.apiHttpPort = 4770   // pin to a known value
        counter.reset()
        AppSettings.shared.apiHttpPort = 4770   // unchanged
        XCTAssertEqual(counter.value, 0, "same value must not post apiSettingsDidChange")
        AppSettings.shared.apiHttpPort = 4771   // changed
        XCTAssertEqual(counter.value, 1, "a real change must post exactly once")
    }

    /// A stop() that lands while start() is still awaiting must resume that
    /// start with a cancellation error instead of leaking the continuation —
    /// the path every mid-startup restart takes through `HTTPServer.start()`.
    /// Cancelling before the first await makes the race deterministic.
    func testStopBeforeReadyCancelsPendingStart() async throws {
        let server = try XCTUnwrap(HTTPServer(parameters: HTTPServerTransport.localhostTCP(port: 0)) { _ in
            APIResponse(status: 404, body: Data())
        })
        server.stop()
        do {
            _ = try await server.start()
            XCTFail("start on a cancelled listener must throw, not return")
        } catch is CancellationError {
            // expected: the only error a cancelled listener may surface
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    /// A settings change lands while the previous start tasks are still in
    /// flight (stop() cancels listeners whose `start()` has not returned
    /// yet). The service must converge on the fresh parameters without a
    /// hang and without the cancelled start clobbering the new state —
    /// this is the real-world path behind `apiSettingsDidChange`.
    func testSettingChangeMidStartupConverges() async throws {
        pinAPI(unixSocket: true, http: true, port: 0)
        let service = APIListenerService(socketPath: tempSocketPath)
        defer { service.stop() }
        service.restart()
        service.restart()   // the AppDelegate observer fires immediately after
        let converged = await waitUntil {
            service.isHttpListening && service.isSocketListening
        }
        XCTAssertTrue(converged, "must converge to both listeners after a mid-startup restart")
        XCTAssertNil(service.httpError, "a cancelled stale start must not report an error")
    }
}
