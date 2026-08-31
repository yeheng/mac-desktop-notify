import CoreGraphics
import Foundation

/// Keeps exactly one instance per connected display.
///
/// A `DynamicNotch` owns one window, and one window cannot be the notch on two
/// displays at once, so multi-display support means one instance per screen kept
/// in step with the screens that actually exist.
///
/// Split out of the presenter because this bookkeeping is what quietly breaks
/// when a monitor is unplugged, and a real `DynamicNotch` cannot be constructed
/// without a window server — which the test target does not have.
@MainActor
final class PerScreenInstances<Instance> {
    private(set) var instances: [CGDirectDisplayID: Instance] = [:]

    var count: Int { instances.count }

    /// Reconciles the map with the displays in `current`.
    ///
    /// `retire` runs once for every display that went away, `make` once for every
    /// new one. Instances for displays that survived are left alone: a screen that
    /// merely changed resolution keeps its window and its animation state.
    func sync(
        current: Set<CGDirectDisplayID>,
        make: (CGDirectDisplayID) -> Instance,
        retire: (Instance) -> Void
    ) {
        let existing = Set(instances.keys)
        for id in existing.subtracting(current) {
            guard let instance = instances.removeValue(forKey: id) else { continue }
            retire(instance)
        }
        for id in current.subtracting(existing) {
            instances[id] = make(id)
        }
    }
}
