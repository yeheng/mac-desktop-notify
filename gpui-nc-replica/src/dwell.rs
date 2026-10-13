//! Swift-compatible dwell holds; elapsed time is independent of UI frame rate.
#[derive(Clone, Default)]
pub(crate) struct DwellClock {
    idle_ms: u64,
    snoozed: bool,
}
pub(crate) enum Tick {
    Hold,
    Count,
    Demote,
}
impl DwellClock {
    pub fn is_snoozed(&self) -> bool {
        self.snoozed
    }
    pub fn tick(
        &mut self,
        elapsed: u64,
        hovered: bool,
        critical: bool,
        actions: bool,
        pending: bool,
        age_out: bool,
    ) -> Tick {
        if hovered {
            self.idle_ms = 0;
            return Tick::Hold;
        }
        self.idle_ms = self.idle_ms.saturating_add(elapsed);
        if pending {
            return Tick::Hold;
        }
        if critical && !self.snoozed {
            if age_out && self.idle_ms >= 300_000 {
                self.snoozed = true;
                self.idle_ms = 0;
                return Tick::Demote;
            }
            return Tick::Hold;
        }
        if actions && self.idle_ms < 300_000 {
            Tick::Hold
        } else {
            Tick::Count
        }
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn unanswered_actions_hold_until_idle_and_hover_resets_hold() {
        let mut clock = DwellClock::default();
        assert!(matches!(
            clock.tick(299_000, false, false, true, false, true),
            Tick::Hold
        ));
        assert!(matches!(
            clock.tick(1000, false, false, true, false, true),
            Tick::Count
        ));
        assert!(matches!(
            clock.tick(1, true, false, true, false, true),
            Tick::Hold
        ));
        assert!(matches!(
            clock.tick(1, false, false, true, false, true),
            Tick::Hold
        ));
    }
    #[test]
    fn critical_aging_is_a_transition_and_can_be_disabled() {
        let mut clock = DwellClock::default();
        assert!(matches!(
            clock.tick(300_000, false, true, false, false, false),
            Tick::Hold
        ));
        assert!(matches!(
            clock.tick(1, false, true, false, false, true),
            Tick::Demote
        ));
        assert!(clock.is_snoozed());
        assert!(matches!(
            clock.tick(1, false, true, false, false, true),
            Tick::Count
        ));
        assert!(matches!(
            clock.tick(1, false, false, false, true, true),
            Tick::Hold
        ));
    }
}
