import Foundation

/// Installs a NotificationCenter observer whose handler runs inline on the
/// main actor.
///
/// `queue: .main` and `MainActor.assumeIsolated` are one contract: delivery
/// already lands on the main thread, so the handler runs inline instead of one
/// Task hop later — and dropping the queue would deliver on the posting
/// thread, where the assertion traps (loudly, which is the point). The pairing
/// used to be copied at every call site; now it is written once, here.
///
/// Handlers that need the `Notification` payload itself keep the explicit
/// `addObserver` form; this helper is for the (far more common) "something
/// changed, re-derive" sites.
@discardableResult
func addObserverOnMain(
    _ center: NotificationCenter = .default,
    forName name: Notification.Name,
    object: Any? = nil,
    using handler: @escaping @MainActor @Sendable () -> Void
) -> NSObjectProtocol {
    center.addObserver(forName: name, object: object, queue: .main) { _ in
        MainActor.assumeIsolated { handler() }
    }
}
