import AtollExtensionKit
import Foundation

/// Minimal XPC host stub for the AtollExtensionKit client SDK.
///
/// AtollExtensionKit provides the *client* side (third-party apps talk to
/// Atoll). This host is the *recipient*: a placeholder XPC listener that
/// would receive incoming live activities / lock-screen widgets / notch
/// experiences and re-broadcast them over the existing ``NotificationEventBus``
/// so they render through the island.
///
/// The full XPC listener (NSXPCListener + Mach service + authorization +
/// extension routing) is non-trivial; this stub stands in the integration
/// point and exposes the async surface the real implementation fills in.
@MainActor
final class AtollExtensionHost {

    private let client: AtollClient
    private(set) var isRunning = false

    init() {
        client = AtollClient.shared
    }

    /// Start listening for incoming extension payloads.
    func start() {
        isRunning = true
        // Placeholder: a real implementation would register an NSXPCListener
        // on AtollXPCConnectionManager.serviceName and decode incoming
        // AtollLiveActivityDescriptor / AtollNotchExperienceDescriptor
        // payloads, re-broadcasting each over NotificationEventBus.
    }

    func stop() {
        isRunning = false
    }

    // MARK: - Client SDK surface (exposed for diagnostics / future wiring)

    var isAtollInstalled: Bool { client.isAtollInstalled }

    func presentLiveActivity(_ descriptor: AtollLiveActivityDescriptor) async throws {
        try await client.presentLiveActivity(descriptor)
    }
}
