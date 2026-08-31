import AppKit
import CoreGraphics
import Foundation
import Observation

/// A reason the user cannot read the screen right now.
///
/// These are tracked as a set rather than a single flag because they overlap in
/// practice: the screensaver starts, the screen then locks, the machine then
/// sleeps. With one boolean, whichever source reports "stopped" first would clear
/// a state another source still owns, and the app would happily present messages
/// to a locked screen.
enum AwaySource: Hashable, Sendable {
    case screenLocked
    case screensaver
    case systemSleep

    var title: String {
        switch self {
        case .screenLocked: "屏幕已锁定"
        case .screensaver: "屏幕保护程序运行中"
        case .systemSleep: "系统睡眠中"
        }
    }
}

/// Watches the machine for signals that the user has stepped away.
///
/// Only signals macOS delivers to every process are used: screen lock/unlock,
/// screensaver start/stop, and sleep/wake. On top of those, the current lock
/// state is *asked for* rather than inferred, because the machine can wake back
/// up into a session that is still locked and no notification will ever arrive
/// to correct us.
///
/// There is deliberately no Focus / Do-Not-Disturb detection. The only way to
/// read it is an undocumented preference key that has moved between macOS
/// releases. A quiet mode that silently stops working after an OS update is
/// worse than not shipping one, so the seam stays open (`setActive`) and the
/// guesswork stays out.
@MainActor
@Observable
final class PresenceMonitor {
    /// True while at least one reason to stay quiet is active.
    private(set) var isAway = false

    /// Which reasons are active. Empty exactly when `isAway` is false.
    private(set) var activeSources: Set<AwaySource> = []

    /// Runs once on each away -> present transition, after the screen is usable.
    var onReturn: (() -> Void)?

    private(set) var isRunning = false

    private let distributed = DistributedNotificationCenter.default()
    private let workspace = NSWorkspace.shared.notificationCenter
    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    // No deinit: under Swift 6 it cannot call into this actor, and relying on
    // deallocation to unregister observers would be wrong anyway — the center
    // retains these tokens until they are removed. Lifecycle is start()/stop(),
    // and this object is retained for the whole app run.

    func start() {
        guard !isRunning else { return }
        isRunning = true

        observeDistributed("com.apple.screenIsLocked", .screenLocked, active: true)
        observeDistributed("com.apple.screenIsUnlocked", .screenLocked, active: false)
        observeDistributed("com.apple.screensaver.didstart", .screensaver, active: true)
        observeDistributed("com.apple.screensaver.didstop", .screensaver, active: false)

        observeWorkspace(NSWorkspace.willSleepNotification, .systemSleep, active: true)
        observeWorkspace(NSWorkspace.didWakeNotification, .systemSleep, active: false)

        // The app may be launching into a session that is already locked, or
        // resuming into one. Ask instead of assuming.
        refreshFromSystem()
    }

    func stop() {
        for token in distributedObservers { distributed.removeObserver(token) }
        for token in workspaceObservers { workspace.removeObserver(token) }
        distributedObservers.removeAll()
        workspaceObservers.removeAll()
        isRunning = false
    }

    /// Applies a source change. This is the only path that mutates `isAway`, so
    /// the return callback can never fire from a state that did not really change.
    ///
    /// Exposed so tests can drive transitions without waiting on the system.
    func setActive(_ active: Bool, for source: AwaySource) {
        let wasAway = isAway
        if active {
            activeSources.insert(source)
        } else {
            activeSources.remove(source)
        }
        isAway = !activeSources.isEmpty
        if wasAway, !isAway {
            onReturn?()
        }
    }

    /// Re-derives the sources that can be asked about rather than heard about.
    ///
    /// Called at start and on wake. Waking also clears the screensaver: it either
    /// ended with the sleep, or it will re-post `didstart` if it comes back.
    private func refreshFromSystem() {
        setActive(Self.screenIsLocked(), for: .screenLocked)
        setActive(false, for: .screensaver)
    }

    /// The current lock state as a question, not an event.
    private static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    private func observeDistributed(_ name: String, _ source: AwaySource, active: Bool) {
        let token = distributed.addObserver(
            forName: NSNotification.Name(name),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setActive(active, for: source) }
        }
        distributedObservers.append(token)
    }

    private func observeWorkspace(_ name: NSNotification.Name, _ source: AwaySource, active: Bool) {
        let token = workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            // Wake needs a re-read: the machine may resume into a locked session,
            // and nothing else will tell us.
            if name == NSWorkspace.didWakeNotification {
                Task { @MainActor [weak self] in
                    self?.setActive(active, for: source)
                    self?.refreshFromSystem()
                }
                return
            }
            Task { @MainActor [weak self] in self?.setActive(active, for: source) }
        }
        workspaceObservers.append(token)
    }
}
