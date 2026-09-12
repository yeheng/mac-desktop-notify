import Foundation

/// The pointer state machine and the §3 dismiss rules.
///
/// `reduce(_:)` is the single switch every pointer edge flows through: what
/// `pointer` becomes, and the effects that follow. No other code writes it.
/// `applyDismissRules` is the adjudication point every state transition ends
/// at - inputs: the open reason, the live card's operability, the pointer
/// position.
extension NotificationManager {
    func reduce(_ intent: PointerIntent) {
        switch intent {
        case .activationZoneEntered:
            guard !pointer.nearIsland else { return }
            // The panel and the activation zone overlap, so a fresh claim can
            // arrive while the pointer is already on the panel. Fold it into
            // the existing state instead of overwriting it - the `onPanel`
            // payload exists precisely to carry this claim. Overwriting it
            // would lose the fact that the pointer is on the panel, and the
            // hover-exit that follows would then be ignored, leaving the card
            // on screen until a click.
            if case .onPanel = pointer.zone {
                pointer.zone = .onPanel(zoneClaimsPointer: true)
            } else {
                pointer.zone = .inActivationZone
            }
            delayed.cancel(.manualCollapse)
            // The zone is larger than the visible pill, so this tick is the
            // earliest "expansion is armed" signal there is - it lands inside
            // the hover delay, before the panel appears.
            if !displayState.isOpened, hasContent {
                IslandHaptics.zoneEntered()
            }
            guard AppSettings.shared.hoverToExpand, hasContent, !displaySuppressed, !pointer.hoverDismissed else { return }
            delayed.schedule(.hoverExpand, after: hoverDelay()) { [weak self] in
                guard let self, self.pointer.nearIsland else { return }
                self.displayState = .opened(reason: .hover)
                self.presentExpanded()
                self.applyDismissRules()
                self.reconcileDwell()
            }

        case .activationZoneExited:
            guard pointer.nearIsland else { return }
            // A genuine exit re-arms hover expansion after a manual dismissal.
            pointer.hoverDismissed = false
            pointer.forgetActivationZoneClaim()
            delayed.cancel(.hoverExpand)
            // §3.2: only a hover-opened panel collapses with the pointer -
            // a click-opened message center is closed by Esc, the close
            // button, or an outside click, never by drift.
            guard case .opened(reason: .hover) = displayState, AppSettings.shared.autoCollapseOnLeave else { return }
            scheduleManualCollapse()

        case .hoverBegan:
            guard !pointer.onPanel else { return }
            pointer.zone = .onPanel(zoneClaimsPointer: pointer.nearIsland)
            delayed.cancel(.manualCollapse)
            if displayState.isOpened {
                // §3.1 latch: entering the open panel engages the card. It gates
                // only the leave-collapse rule - read state is explicit (v4 §4),
                // so nothing is marked read here.
                pointer.panelEverEntered = true
            }
            applyDismissRules()
            reconcileDwell()

        case .hoverEnded:
            guard pointer.onPanel else { return }
            let claims = pointer.nearIsland
            pointer.zone = claims ? .inActivationZone : .away
            if case .opened(reason: .notification) = displayState, pointer.panelEverEntered {
                // §3.1: entered, then left - the card was seen; it steps down now.
                advance()
                return
            }
            if case .opened(reason: .hover) = displayState, !claims, AppSettings.shared.autoCollapseOnLeave {
                scheduleManualCollapse()
            }
            applyDismissRules()
            reconcileDwell()

        case .panelDismissed:
            // Nothing is hover-expandable until the pointer genuinely leaves
            // the zone. The panel's own hover report survives the collapse:
            // the pointer may still be where the panel was, and a fresh push
            // can reopen the panel right under it - its dwell must stay held.
            pointer.hoverDismissed = true
            pointer.forgetActivationZoneClaim()

        case .displaySuppressed:
            pointer.forgetActivationZoneClaim()

        case .islandClicked:
            // An explicit click is the user overriding the dismissal ban.
            pointer.hoverDismissed = false

        case .cleared:
            pointer = PointerState()
        }
    }

    /// Called by the expanded content. Hovering pauses transient dwell time.
    func setHovering(_ hovering: Bool) {
        reduce(hovering ? .hoverBegan : .hoverEnded)
    }

    /// Called by the global mouse monitor for the full compact island activation zone.
    func setPointerNearIsland(_ near: Bool) {
        reduce(near ? .activationZoneEntered : .activationZoneExited)
    }

    // MARK: - Dismiss rules (§3)
    //
    // One adjudication point every state transition ends at. Inputs: the open
    // reason, the live card's policy, the pointer position. It owns exactly one
    // timer - the info card's auto-close - and cancels it up front so every call
    // site re-derives from scratch.

    func applyDismissRules() {
        delayed.cancel(.notificationAutoClose)
        guard case .opened(reason: .notification) = displayState,
              let live = presentation,
              !displaySuppressed,
              // Operable cards never auto-close: their exit paths are the action
              // itself, idle aging (§8), or a manual close. The table says which
              // cards those are; this function no longer re-derives it.
              let after = live.policy.autoCloseAfter,
              !pointer.onPanel else { return }
        delayed.schedule(.notificationAutoClose, after: after) { [weak self] in
            guard let self,
                  self.displayState.openReason == .notification,
                  self.presentation != nil else { return }
            self.advance()
        }
    }

    /// Whether `Esc` may close the panel.
    ///
    /// Derived, not stored: the panel is Esc-able when the pointer is on it, or
    /// when the user opened it deliberately (click, hover, or the keyboard). A
    /// panel that pushed itself open on an untouched screen is not something
    /// `Esc` should reach into - firing from the global monitor would otherwise
    /// collapse it on every `Esc` press in vim and friends.
    var canDismissWithEscape: Bool {
        if case .opened(let reason) = displayState, reason != .notification { return true }
        return pointerNearPanel
    }

    private func scheduleManualCollapse() {
        delayed.schedule(.manualCollapse, after: .milliseconds(260)) { [weak self] in
            guard let self, self.pointer.completelyGone else { return }
            // The one settle path decides where the display lands — and which
            // timers die with it (a stale `.hoverExpand` must not outlive this
            // collapse). The body used to duplicate `settleDisplay` inline and
            // had already drifted: it forgot the `.hoverExpand` cancel.
            self.settleDisplay(liveMessage: self.current != nil)
        }
    }

    private func hoverDelay() -> Duration {
        Duration.milliseconds(Int(AppSettings.shared.hoverDelayMilliseconds))
    }
}
