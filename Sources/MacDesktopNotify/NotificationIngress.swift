import Foundation

/// The one way a sender's message enters the app.
///
/// Every transport used to spell out the same steps by hand - validate, push,
/// and *remember* to run the script backfill. The backfill was duplicated in
/// three of them (URL scheme, HTTP, WebSocket), which is exactly how the fourth
/// door gets written without it. Worse, the script backfill path had already
/// grown its own copy of the field rules and wrote a non-finite timeout straight
/// into the model, which killed persistence for the rest of the session.
///
/// So: a door that can deliver a `script` field calls `deliver` and gets the
/// backfill whether it remembered it or not.
///
/// Deliberately *not* a door itself: the script layer's own pushes (`notify.push`
/// inside a run, failure diagnostics) push directly, because a) `notify.push`
/// refuses the `script` field by construction, so it has no backfill to forget,
/// and b) routing them here would be a call back into the layer that called us.
@MainActor
enum NotificationIngress {
    /// Delivers a validated message to the model.
    ///
    /// Sound is not here on purpose: the manager fires `soundPlayer` inside
    /// `push`, exactly when a message turns `.displayed`, so no door can sound
    /// a withheld message or stay silent about a shown one.
    @discardableResult
    static func deliver(
        _ notification: NotchNotification,
        to manager: NotificationManager = .shared,
        runner: ScriptRunner = .shared
    ) -> PushOutcome {
        let outcome = manager.push(notification)
        if notification.script != nil {
            Task { await runner.backfill(notification: notification) }
        }
        return outcome
    }
}
