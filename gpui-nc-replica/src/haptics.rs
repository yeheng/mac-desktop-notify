// objc 0.2 `msg_send!` probes a legacy cargo-clippy cfg.
#![allow(unexpected_cfgs)]

//! Haptic feedback for card interactions on macOS.
//!
//! The trackpad's haptic engine is the only confirmation channel that does
//! not depend on looking — the notch sits where the eyes usually are not.
//! Kept deliberately sparse (expand / close / swipe / click); anything more
//! becomes buzzing. `NC_HAPTICS=0` and the settings toggle disable it.

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HapticPattern {
    /// Subtle feedback for expanding a card.
    Expand,
    /// Feedback for closing/dismissing a card.
    Close,
    /// Feedback for swiping a card away.
    Swipe,
    /// Feedback for clicking through.
    Click,
}

/// Haptic feedback gate.
pub struct Haptics {
    enabled: bool,
}

impl Haptics {
    pub fn new(enabled: bool) -> Self {
        Self { enabled }
    }

    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    #[cfg(test)]
    pub(crate) fn is_enabled(&self) -> bool {
        self.enabled
    }

    /// Trigger a haptic feedback pattern. Swift `SurfaceHaptics` funnels every
    /// site through one generic pattern — the vocabulary is the four sites,
    /// not the pattern IDs.
    pub fn trigger(&self, pattern: HapticPattern) {
        let _ = pattern;
        if !self.enabled {
            return;
        }
        #[cfg(target_os = "macos")]
        {
            use objc::runtime::Object;
            use objc::{class, msg_send, sel, sel_impl};
            unsafe {
                // NSHapticFeedbackPattern.generic = 0,
                // NSHapticFeedbackPerformanceTime.default = 0.
                let performer: *mut Object =
                    msg_send![class!(NSHapticFeedbackManager), defaultPerformer];
                if !performer.is_null() {
                    let _: () = msg_send![
                        performer,
                        performFeedbackPattern: 0isize
                        performanceTime: 0isize
                    ];
                }
            }
        }
    }

    pub fn expand(&self) {
        self.trigger(HapticPattern::Expand);
    }

    pub fn close(&self) {
        self.trigger(HapticPattern::Close);
    }

    pub fn swipe(&self) {
        self.trigger(HapticPattern::Swipe);
    }

    pub fn click(&self) {
        self.trigger(HapticPattern::Click);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn enabled_by_default_and_can_be_disabled() {
        let mut haptics = Haptics::new(true);
        assert!(haptics.is_enabled());
        haptics.set_enabled(false);
        assert!(!haptics.is_enabled());
    }

    #[test]
    fn trigger_respects_the_gate() {
        // Every pattern routes through trigger(); with the gate off it must
        // not even reach the platform seam. (A test cannot observe a
        // vibration, so this documents the contract.)
        let haptics = Haptics::new(false);
        haptics.expand();
        haptics.close();
        haptics.swipe();
        haptics.click();
    }
}
