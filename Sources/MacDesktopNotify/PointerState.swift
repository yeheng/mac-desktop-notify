import Foundation

/// Where the pointer is relative to the island, as one value. Tracked (not
/// ignored) by the manager because `pointerNearIsland` derives from it and
/// the compact pill's pre-expansion cue reads that. All transitions flow
/// through `NotificationManager.reduce(_:)` (+Pointer); nothing else writes it.
///
/// Two sensors report into one machine: the global monitor tracks the
/// compact activation zone, the expanded panel's own hover tracks the
/// panel. Their regions overlap, so `onPanel` carries the monitor's latest
/// claim - a hover edge cannot re-derive it, and the hover-exit transition
/// needs it to know whether the pointer stayed in the zone or left the
/// island entirely. This replaces the `isHovering` / `pointerNearIsland` /
/// `hoverSuppressedUntilExit` booleans whose combinations every call site
/// had to keep consistent by hand.
struct PointerState: Equatable {
    enum Zone: Equatable {
        /// Gone from the island.
        case away
        /// Inside the compact activation zone, not on the panel.
        case inActivationZone
        /// Hovering the expanded panel; the payload is the activation-zone
        /// monitor's latest claim.
        case onPanel(zoneClaimsPointer: Bool)
    }

    var zone: Zone = .away

    /// The latch a panel dismissal arms: hover expansion stays banned
    /// until the pointer genuinely exits the activation zone, so a 1px
    /// jiggle cannot reopen a panel the user just closed. An explicit
    /// island click overrides it.
    var hoverDismissed = false

    /// §3.1 latch: the pointer has been on the open panel during this open
    /// period. Gates only the leave-collapse rule; v4 read state is explicit
    /// and never consults it. Set on the `.hoverBegan` edge, cleared when the
    /// panel settles. It lives here - not as a loose manager flag - so the
    /// pointer's whole lifecycle is one value with one reset point.
    var panelEverEntered = false

    /// The activation-zone monitor's claim - what `pointerNearIsland` reports.
    var nearIsland: Bool {
        switch zone {
        case .away: return false
        case .inActivationZone: return true
        case .onPanel(let claims): return claims
        }
    }

    /// Whether the panel is being hovered - what `isHovering` used to gate.
    var onPanel: Bool {
        if case .onPanel = zone { return true }
        return false
    }

    /// Whether the pointer is gone from the island entirely - the
    /// `!isHovering && !pointerNearIsland` combination every guard used
    /// to spell out.
    var completelyGone: Bool {
        if case .away = zone { return true }
        return false
    }

    /// Forgets the activation-zone claim without touching what the panel's
    /// own hover reported - the synthetic reset a dismissal or a display
    /// suppression performs. The claim being already false is what makes
    /// the monitor's next real exit a no-op, which is exactly how the
    /// dismissal ban holds until a genuine zone crossing.
    mutating func forgetActivationZoneClaim() {
        switch zone {
        case .away:
            break
        case .inActivationZone:
            zone = .away
        case .onPanel:
            zone = .onPanel(zoneClaimsPointer: false)
        }
    }
}

/// What the outside world reports about the pointer, as an intent. The
/// public setters keep their signatures (views and the presenter call
/// them); they only translate into these.
enum PointerIntent {
    /// Global monitor: pointer entered the compact activation zone.
    case activationZoneEntered
    /// Global monitor: pointer left the compact activation zone.
    case activationZoneExited
    /// Expanded panel: pointer started hovering it.
    case hoverBegan
    /// Expanded panel: pointer stopped hovering it.
    case hoverEnded
    /// The close button / Esc: the panel is gone and hover stays banned
    /// until a genuine zone crossing.
    case panelDismissed
    /// A fullscreen app took the display: forget the zone claim, the
    /// presenter stands down entirely.
    case displaySuppressed
    /// An explicit click on the island: the user overrides the ban.
    case islandClicked
    /// `clear()`: everything resets.
    case cleared
}
