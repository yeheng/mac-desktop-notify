//! 「稍后提醒」bookkeeping, ported from Swift `remindMeLater`/`resurfaceReminder`.
//!
//! Swift semantics this must keep:
//! - **One reminder in flight at a time.** `snoozedReminderItem` is a single
//!   optional; scheduling a new one silently replaces the old.
//! - The card retires immediately — stays in history, stays **unread**.
//! - When the reminder fires, the message re-presents like a new push but
//!   **never re-enters history** (it never left).
//! - The reminder is silently dropped if the message was read, deleted,
//!   cleared, or quiet mode holds at fire time.
//!
//! Pure bookkeeping lives here (testable without a window server); the
//! history/read/quiet guards run in `Store::resurface_due`.

use std::time::{Duration, Instant};

use crate::api::Notification;

/// How long a reminder waits before the message comes back.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum SnoozeDuration {
    Minutes30,
    Hours1,
}

impl SnoozeDuration {
    pub(crate) fn duration(self) -> Duration {
        match self {
            Self::Minutes30 => Duration::from_secs(30 * 60),
            Self::Hours1 => Duration::from_secs(60 * 60),
        }
    }
}

/// The single in-flight reminder.
#[derive(Clone, Debug)]
pub(crate) struct Reminder {
    pub(crate) notification: Notification,
    pub(crate) due_at: Instant,
}

/// Single-slot reminder book. Replacing and invalidating are the whole API —
/// firing just hands the reminder back; the caller applies the guards.
#[derive(Default)]
pub(crate) struct ReminderBook {
    pending: Option<Reminder>,
}

impl ReminderBook {
    pub(crate) fn new() -> Self {
        Self { pending: None }
    }

    /// Schedules `notification`, replacing any reminder already in flight.
    /// Returns the reminder that was evicted, if any.
    pub(crate) fn schedule(
        &mut self,
        notification: Notification,
        duration: SnoozeDuration,
    ) -> Option<Reminder> {
        self.pending.replace(Reminder {
            notification,
            due_at: Instant::now() + duration.duration(),
        })
    }

    /// The pending reminder's notification id, if a reminder is in flight.
    pub(crate) fn pending_id(&self) -> Option<uuid::Uuid> {
        self.pending.as_ref().map(|r| r.notification.id)
    }

    /// Cancels the pending reminder when it matches `id` (read / deleted).
    pub(crate) fn cancel_if_matches(&mut self, id: uuid::Uuid) {
        if self.pending_id() == Some(id) {
            self.pending = None;
        }
    }

    /// Cancels when the pending notification belongs to `group` — `None`
    /// means a clear-all. Mirrors `clear`'s group semantics.
    pub(crate) fn cancel_if_group(&mut self, group: Option<&str>) {
        let matches = self.pending.as_ref().is_some_and(|r| {
            group.is_none() || r.notification.group.as_deref() == group.map(str::trim)
        });
        if matches {
            self.pending = None;
        }
    }

    /// Takes the reminder if it is due at `now`, clearing the slot.
    /// Not-yet-due reminders stay booked. The clock is a parameter so tests
    /// can fire without sleeping. The poller scans every second, so no
    /// cadence bookkeeping is needed alongside this.
    pub(crate) fn take_due(&mut self, now: Instant) -> Option<Reminder> {
        let due = self.pending.as_ref().is_some_and(|r| r.due_at <= now);
        due.then(|| self.pending.take()).flatten()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn notification(id: uuid::Uuid, group: Option<&str>) -> Notification {
        crate::api::validate(
            &serde_json::to_vec(&serde_json::json!({
                "title": "Test", "group": group
            }))
            .unwrap(),
        )
        .unwrap()
        .tap_id(id)
    }

    /// The validator assigns fresh UUIDs; patch it for stable test ids.
    trait TapId {
        fn tap_id(self, id: uuid::Uuid) -> Notification;
    }
    impl TapId for Notification {
        fn tap_id(mut self, id: uuid::Uuid) -> Notification {
            self.id = id;
            self
        }
    }

    #[test]
    fn scheduling_replaces_the_single_in_flight_reminder() {
        let mut book = ReminderBook::new();
        let first = notification(uuid::Uuid::new_v4(), None);
        let second = notification(uuid::Uuid::new_v4(), None);

        assert!(book.schedule(first.clone(), SnoozeDuration::Minutes30).is_none());
        let evicted = book
            .schedule(second.clone(), SnoozeDuration::Hours1)
            .expect("second schedule must evict the first");
        assert_eq!(evicted.notification.id, first.id);
        assert_eq!(book.pending_id(), Some(second.id));
    }

    #[test]
    fn read_and_delete_cancel_the_matching_reminder_only() {
        let mut book = ReminderBook::new();
        let id = uuid::Uuid::new_v4();
        book.schedule(notification(id, None), SnoozeDuration::Minutes30);

        book.cancel_if_matches(uuid::Uuid::new_v4());
        assert_eq!(book.pending_id(), Some(id), "other ids must not cancel");

        book.cancel_if_matches(id);
        assert_eq!(book.pending_id(), None);
        assert!(book.take_due(Instant::now()).is_none(), "nothing booked");
    }

    #[test]
    fn group_clear_cancels_only_that_group() {
        let mut book = ReminderBook::new();
        let id = uuid::Uuid::new_v4();
        book.schedule(notification(id, Some("ci")), SnoozeDuration::Minutes30);

        book.cancel_if_group(Some("other"));
        assert_eq!(book.pending_id(), Some(id));
        book.cancel_if_group(Some(" ci "));
        assert_eq!(book.pending_id(), None, "trimmed group must match");

        book.schedule(notification(id, Some("ci")), SnoozeDuration::Minutes30);
        book.cancel_if_group(Some("other"));
        book.cancel_if_group(None); // clear-all
        assert_eq!(book.pending_id(), None);
    }

    #[test]
    fn take_due_only_fires_when_the_deadline_passed() {
        let mut book = ReminderBook::new();
        let id = uuid::Uuid::new_v4();
        book.schedule(notification(id, None), SnoozeDuration::Minutes30);

        let now = Instant::now();
        assert!(book.take_due(now).is_none(), "30 minutes are not due yet");
        assert_eq!(book.pending_id(), Some(id), "undue reminders stay booked");

        let fired = book
            .take_due(now + Duration::from_secs(31 * 60))
            .expect("deadline passed");
        assert_eq!(fired.notification.id, id);
        assert_eq!(book.pending_id(), None);
        assert!(book.take_due(now + Duration::from_secs(31 * 60)).is_none());
    }
}
