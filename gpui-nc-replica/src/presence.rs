//! macOS presence detection: lock screen / screensaver / sleep monitoring.
//!
//! Uses polling of system state on macOS. Only public macOS signals are used —
//! no undocumented Focus APIs.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

/// A reason the user cannot read the screen right now.
///
/// Kept as the Swift-shaped set even though the polling loop currently only
/// samples the lock state: screensaver/sleep sessions in practice co-occur
/// with a locked session, which the poll re-reads every cycle. The variants
/// stay so the seam can grow into them without a shape change.
#[allow(dead_code)]
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum AwaySource {
    ScreenLocked,
    Screensaver,
    SystemSleep,
}

/// What happens to notifications when the user is away.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AwayBehavior {
    /// Notifications display normally even when away.
    Off,
    /// Silent: go to history only, no on-screen display.
    #[default]
    HistoryOnly,
    /// Only critical/urgent notifications display.
    CriticalOnly,
}

impl AwayBehavior {
    /// The settings copy for each mode (Swift `QuietMode`'s labels).
    pub fn label(&self) -> &'static str {
        match self {
            Self::Off => "照常显示",
            Self::HistoryOnly => "静默存入历史",
            Self::CriticalOnly => "仅紧急穿透",
        }
    }
}

/// Shared state for the presence monitor.
pub struct PresenceState {
    is_away: AtomicBool,
    sources: Mutex<Vec<AwaySource>>,
    behavior: Mutex<AwayBehavior>,
    /// A fullscreen app owns the banner display right now — a separate
    /// suppression path from away: Swift hides the toast entirely (messages
    /// still record to history), regardless of urgency.
    fullscreen_suppressed: AtomicBool,
    fullscreen_hide_enabled: AtomicBool,
}

impl PresenceState {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            is_away: AtomicBool::new(false),
            sources: Mutex::new(Vec::new()),
            behavior: Mutex::new(AwayBehavior::HistoryOnly),
            fullscreen_suppressed: AtomicBool::new(false),
            // Swift's "全屏应用中隐藏" defaults on; the boot config (env
            // `NC_FULLSCREEN_HIDE`, settings) drives it from here on.
            fullscreen_hide_enabled: AtomicBool::new(true),
        })
    }

    pub fn is_away(&self) -> bool {
        self.is_away.load(Ordering::Relaxed)
    }

    pub fn set_behavior(&self, behavior: AwayBehavior) {
        *self.behavior.lock().unwrap() = behavior;
    }

    /// Toggle the fullscreen gate (settings「全屏应用中隐藏」, env
    /// `NC_FULLSCREEN_HIDE` at boot).
    pub fn set_fullscreen_hide_enabled(&self, enabled: bool) {
        self.fullscreen_hide_enabled.store(enabled, Ordering::Relaxed);
    }

    pub fn behavior(&self) -> AwayBehavior {
        *self.behavior.lock().unwrap()
    }

    pub fn set_fullscreen_suppressed(&self, suppressed: bool) {
        self.fullscreen_suppressed
            .store(suppressed, Ordering::Relaxed);
    }

    pub fn is_fullscreen_suppressed(&self) -> bool {
        self.fullscreen_hide_enabled.load(Ordering::Relaxed)
            && self.fullscreen_suppressed.load(Ordering::Relaxed)
    }

    pub fn fullscreen_hide_enabled(&self) -> bool {
        self.fullscreen_hide_enabled.load(Ordering::Relaxed)
    }

    /// Whether a notification should be withheld (not shown on screen).
    ///
    /// Two independent gates, both Swift-faithful:
    /// - fullscreen ownership hides everything (no urgency carve-out);
    /// - away follows the configured behavior, critical piercing `CriticalOnly`.
    pub fn should_withhold(&self, is_critical: bool) -> bool {
        if self.is_fullscreen_suppressed() {
            return true;
        }
        if !self.is_away() {
            return false;
        }
        match self.behavior() {
            AwayBehavior::Off => false,
            AwayBehavior::HistoryOnly => true,
            AwayBehavior::CriticalOnly => !is_critical,
        }
    }

    /// Apply an away source change. Returns true if the away state changed.
    pub fn set_source_active(&self, source: AwaySource, active: bool) -> bool {
        let mut sources = self.sources.lock().unwrap();
        let was_away = !sources.is_empty();
        if active {
            if !sources.contains(&source) {
                sources.push(source);
            }
        } else {
            sources.retain(|s| s != &source);
        }
        let is_away = !sources.is_empty();
        self.is_away.store(is_away, Ordering::Relaxed);
        was_away != is_away
    }
}

/// Polls system state to detect lock screen / screensaver / sleep.
///
/// On macOS, we use `ioreg` and `CGSessionCopyCurrentDictionary` equivalents
/// via shell commands to detect the lock state. This is more reliable than
/// trying to set up distributed notification observers from Rust.
#[cfg(target_os = "macos")]
pub struct PresenceMonitor {
    state: Arc<PresenceState>,
    running: Arc<AtomicBool>,
}

#[cfg(target_os = "macos")]
impl PresenceMonitor {
    pub fn new(state: Arc<PresenceState>) -> Self {
        Self {
            state,
            running: Arc::new(AtomicBool::new(false)),
        }
    }

    /// Start monitoring. Spawns a background polling thread.
    ///
    /// Swift observes distributed notifications; here we poll the two states
    /// that can be asked of the system (`CGSessionCopyCurrentDictionary` for
    /// the lock, the WindowServer for fullscreen ownership) every couple of
    /// seconds. Polling also covers the launch-or-wake-into-locked-session case
    /// for free, which Swift handles with an explicit re-read on wake.
    pub fn start(&self) {
        if self.running.swap(true, Ordering::Relaxed) {
            return;
        }
        let state = self.state.clone();
        let running = self.running.clone();
        std::thread::spawn(move || {
            while running.load(Ordering::Relaxed) {
                // The lock state is a question, not an event: `None` (session
                // dictionary unavailable, e.g. mid-sleep) leaves the current
                // state untouched rather than assuming unlocked.
                if let Some(locked) = crate::macos::session_locked() {
                    state.set_source_active(AwaySource::ScreenLocked, locked);
                }
                if state.fullscreen_hide_enabled() {
                    if let Some(suppressed) = crate::screen_probe::probe_suppressed() {
                        state.set_fullscreen_suppressed(suppressed);
                    }
                }
                std::thread::sleep(std::time::Duration::from_secs(2));
            }
        });
    }
}

#[cfg(not(target_os = "macos"))]
pub struct PresenceMonitor;

#[cfg(not(target_os = "macos"))]
impl PresenceMonitor {
    pub fn new(_state: Arc<PresenceState>) -> Self {
        Self
    }
    pub fn start(&self) {}
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn away_behavior_withholding() {
        let state = PresenceState::new();
        assert!(!state.should_withhold(false));
        assert!(!state.should_withhold(true));

        state.set_source_active(AwaySource::ScreenLocked, true);
        assert!(state.is_away());

        state.set_behavior(AwayBehavior::HistoryOnly);
        assert!(state.should_withhold(false));
        assert!(state.should_withhold(true));

        state.set_behavior(AwayBehavior::CriticalOnly);
        assert!(!state.should_withhold(true));
        assert!(state.should_withhold(false));

        state.set_behavior(AwayBehavior::Off);
        assert!(!state.should_withhold(false));
        assert!(!state.should_withhold(true));
    }

    #[test]
    fn fullscreen_suppression_hides_everything_independently_of_away() {
        let state = PresenceState::new();
        state.set_behavior(AwayBehavior::Off);
        state.set_fullscreen_suppressed(true);
        // Not away at all — fullscreen alone still withholds, even critical.
        assert!(state.should_withhold(false));
        assert!(state.should_withhold(true));

        state.set_fullscreen_hide_enabled(false);
        assert!(!state.should_withhold(false), "opted out");

        state.set_fullscreen_hide_enabled(true);
        state.set_fullscreen_suppressed(false);
        assert!(!state.should_withhold(false), "no fullscreen owner");
    }

    #[test]
    fn multiple_sources() {
        let state = PresenceState::new();
        state.set_source_active(AwaySource::ScreenLocked, true);
        assert!(state.is_away());
        state.set_source_active(AwaySource::Screensaver, true);
        assert!(state.is_away());
        state.set_source_active(AwaySource::ScreenLocked, false);
        assert!(state.is_away()); // Still away due to screensaver
        state.set_source_active(AwaySource::Screensaver, false);
        assert!(!state.is_away());
    }
}
