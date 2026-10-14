//! Swift-compatible dwell holds; elapsed time is independent of UI frame rate.
//!
//! "When does this card live" is a table — `DwellPolicy::resolve` — computed
//! once when the card goes live (and again after a script backfill rewrites
//! its fields). The state machine only *applies* it: this file never looks at
//! urgency, actions or settings.

use std::time::Duration;

use crate::api::Notification;

/// The durations `DwellPolicy` is built from (Swift `DwellTiming`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct DwellTiming {
    /// Sender timeout fallback: how long a plain card lives.
    pub dwell: Duration,
    /// A hold nobody is looking at is released after this long.
    pub action_hold_idle: Duration,
    /// An untouched blocking card ages out after this long.
    pub critical_idle: Duration,
    /// The budget a demoted («稍后处理») card runs on.
    pub critical_snooze: Duration,
}

impl Default for DwellTiming {
    fn default() -> Self {
        Self {
            dwell: Duration::from_secs(5),
            action_hold_idle: Duration::from_secs(300),
            critical_idle: Duration::from_secs(300),
            critical_snooze: Duration::from_secs(300),
        }
    }
}

/// How long a live card lives, as one value — Swift `DwellPolicy` 的表：
///
/// | urgency  | actions | budget             | holds | ages out                  |
/// |----------|---------|--------------------|-------|---------------------------|
/// | critical | -       | none (blocks)      | no    | 5 min, then 5 min running |
/// | other    | yes     | timeout ?? dwell   | yes   | no                        |
/// | other    | no      | timeout ?? dwell   | no    | no                        |
///
/// (Swift's `autoCloseAfter` is absent: this app opens a detail window
/// instead of expanding cards in place.)
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct DwellPolicy {
    /// Countdown before the card retires itself; `None` means it blocks.
    pub budget: Option<Duration>,
    /// Unanswered actions suspend the countdown until the hold ages out.
    pub hold_for_actions: bool,
    /// A blocking card stops hogging the screen after this long (`None` =
    /// `ageOutCriticals` off). Once it fires, the card runs `age_out_budget`.
    pub age_out_after: Option<Duration>,
    pub age_out_budget: Duration,
    /// How long the actions hold lasts.
    pub hold_release_after: Option<Duration>,
    /// A script backfill is still in flight: the card waits for its content.
    pub script_pending: bool,
}

impl DwellPolicy {
    /// The single answer to "how long does this card live", resolved from the
    /// card's fields and the settings at the moment it goes live. A card that
    /// grows actions or turns critical is re-ruled by its new shape.
    pub fn resolve(
        notification: &Notification,
        script_pending: bool,
        age_out_criticals: bool,
        timing: DwellTiming,
    ) -> Self {
        if notification.is_critical() {
            return Self {
                budget: None,
                hold_for_actions: false,
                age_out_after: age_out_criticals.then_some(timing.critical_idle),
                age_out_budget: timing.critical_snooze,
                hold_release_after: None,
                script_pending,
            };
        }
        let has_actions = !notification.actions.is_empty();
        Self {
            // A zero budget would strand the message; the floor is the table's.
            budget: Some(
                notification
                    .timeout
                    .map(Duration::try_from_secs_f64)
                    .and_then(Result::ok)
                    .unwrap_or(timing.dwell)
                    .max(Duration::from_millis(100)),
            ),
            hold_for_actions: has_actions,
            age_out_after: None,
            age_out_budget: timing.critical_snooze,
            hold_release_after: has_actions.then_some(timing.action_hold_idle),
            script_pending,
        }
    }

    /// The same card after «稍后处理» (or after aging out on its own): no
    /// longer blocking, running on the snooze budget. It is a *transition*,
    /// not a field edit — the card that was blocking now has a countdown, so
    /// its actions hold that countdown ("the sender is still waiting") and
    /// the release timer must be armed with it.
    pub fn demoted(self, has_actions: bool, timing: DwellTiming) -> Self {
        Self {
            budget: Some(self.age_out_budget),
            hold_for_actions: has_actions,
            age_out_after: None,
            age_out_budget: self.age_out_budget,
            hold_release_after: has_actions.then_some(timing.action_hold_idle),
            script_pending: self.script_pending,
        }
    }
}

/// Per-card idle tracker: hover resets the idle window, and the countdown
/// only runs when `tick` says `Count`.
#[derive(Clone, Default)]
pub(crate) struct DwellClock {
    idle: Duration,
}

pub(crate) enum Tick {
    Hold,
    Count,
    Demote,
}

impl DwellClock {
    /// One timer tick. `elapsed` is the on-screen wall time since the
    /// previous tick (`counted_elapsed` supplies it).
    pub fn tick(&mut self, elapsed: Duration, hovered: bool, policy: DwellPolicy) -> Tick {
        if hovered {
            self.idle = Duration::ZERO;
            return Tick::Hold;
        }
        self.idle += elapsed;
        if policy.script_pending {
            return Tick::Hold;
        }
        if policy.budget.is_none() {
            // A blocking card ages out into its snooze budget — one-shot, so
            // the idle window restarts for the next hold.
            return match policy.age_out_after {
                Some(after) if self.idle >= after => {
                    self.idle = Duration::ZERO;
                    Tick::Demote
                }
                _ => Tick::Hold,
            };
        }
        if policy.hold_for_actions && self.idle < policy.hold_release_after.unwrap_or_default() {
            return Tick::Hold;
        }
        Tick::Count
    }
}

/// The visible time one tick may count: the intersection of "since the
/// previous tick" and "since the card went visible" — min is exactly that
/// (`now - max(prev_tick, went_visible)`), so the first tick after the
/// enter animation never counts the animation's own time.
pub(crate) fn counted_elapsed(since_tick: Duration, since_visible: Duration) -> Duration {
    since_tick.min(since_visible)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn card(urgency: &str, actions: bool) -> Notification {
        let mut payload = json!({"title": "x", "urgency": urgency});
        if actions {
            payload["actions"] = json!([{"label": "ok", "url": "https://x.example"}]);
        }
        crate::api::validate(&serde_json::to_vec(&payload).unwrap()).unwrap()
    }

    #[test]
    fn unanswered_actions_hold_until_idle_and_hover_resets_hold() {
        let mut clock = DwellClock::default();
        let policy = DwellPolicy::resolve(&card("normal", true), false, true, DwellTiming::default());
        assert!(matches!(
            clock.tick(Duration::from_millis(299_000), false, policy),
            Tick::Hold
        ));
        assert!(matches!(
            clock.tick(Duration::from_millis(1000), false, policy),
            Tick::Count
        ));
        assert!(matches!(
            clock.tick(Duration::from_millis(1), true, policy),
            Tick::Hold
        ));
        // Hover reset the idle window: the hold starts over.
        assert!(matches!(
            clock.tick(Duration::from_millis(1), false, policy),
            Tick::Hold
        ));
    }

    #[test]
    fn critical_ages_out_once_and_then_counts_down() {
        let mut clock = DwellClock::default();
        let policy = DwellPolicy::resolve(&card("critical", false), false, true, DwellTiming::default());
        assert!(matches!(
            clock.tick(Duration::from_millis(299_999), false, policy),
            Tick::Hold
        ));
        assert!(matches!(
            clock.tick(Duration::from_millis(2), false, policy),
            Tick::Demote
        ));
        // The demote transition re-rules the card; the fresh idle window then
        // counts on its snooze budget instead of demoting twice.
        let demoted = policy.demoted(false, DwellTiming::default());
        assert!(matches!(
            clock.tick(Duration::from_millis(1), false, demoted),
            Tick::Count
        ));
    }

    #[test]
    fn critical_aging_can_be_disabled() {
        let mut clock = DwellClock::default();
        let policy = DwellPolicy::resolve(&card("critical", false), false, false, DwellTiming::default());
        assert!(matches!(
            clock.tick(Duration::from_secs(3600), false, policy),
            Tick::Hold
        ));
    }

    #[test]
    fn script_pending_holds_regardless_of_shape() {
        let mut clock = DwellClock::default();
        let policy = DwellPolicy::resolve(&card("normal", false), true, true, DwellTiming::default());
        assert!(matches!(
            clock.tick(Duration::from_secs(3600), false, policy),
            Tick::Hold
        ));
    }

    #[test]
    fn demoted_critical_with_actions_gains_the_hold() {
        let mut clock = DwellClock::default();
        let policy = DwellPolicy::resolve(&card("critical", true), false, true, DwellTiming::default());
        assert!(matches!(
            clock.tick(Duration::from_millis(300_000), false, policy),
            Tick::Demote
        ));
        let demoted = policy.demoted(true, DwellTiming::default());
        assert!(matches!(
            clock.tick(Duration::from_millis(1), false, demoted),
            Tick::Hold
        ));
    }

    #[test]
    fn counted_elapsed_is_the_interval_intersection() {
        let tick = Duration::from_millis(250);
        // First tick after the enter animation: only 100ms were visible.
        assert_eq!(counted_elapsed(tick, Duration::from_millis(100)), Duration::from_millis(100));
        // Later ticks: the tick delta is the smaller bound.
        assert_eq!(counted_elapsed(tick, Duration::from_secs(60)), tick);
    }
}
