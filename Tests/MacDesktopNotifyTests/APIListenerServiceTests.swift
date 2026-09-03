import XCTest
@testable import MacDesktopNotify

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

    /// A stop() that lands while start() is still awaiting must resume that
    /// start with a cancellation error instead of leaking the continuation —
    /// the path every mid-startup restart takes through `HTTPServer.start()`.
    /// Cancelling before the first await makes the race deterministic.
    func testStopBeforeReadyCancelsPendingStart() async throws {
        let server = HTTPServer(parameters: HTTPServerTransport.localhostTCP(port: 0)) { _ in
            APIResponse(status: 404, body: Data())
        }
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
