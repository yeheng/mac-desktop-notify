import Foundation
import os

/// Failures the app chose to continue past.
///
/// This codebase has ~40 `try?` sites, and most of them are fine: a best-effort
/// cleanup that fails costs nothing. The ones that are *not* fine are the ones
/// where somebody is waiting - a sender polling for a receipt, a user whose
/// history should have been saved, a client reading a response body. Those get a
/// trace here, so "it quietly stopped working" is never the only symptom.
///
/// The rule is not "never swallow". It is: swallowing has to be a decision.
enum Diagnostics {
    private static let logger = Logger(subsystem: "MacDesktopNotify", category: "degrade")

    /// Records a failure that was continued past.
    static func degrade(
        _ what: String,
        _ error: Error,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        logger.error(
            "\(what, privacy: .public)：\(String(describing: error), privacy: .public) [\(String(describing: file), privacy: .public):\(line)]"
        )
    }

    /// Same, for the paths that already reduced the failure to a reason string.
    static func degrade(
        _ what: String,
        reason: String,
        file: StaticString = #fileID,
        line: UInt = #line
    ) {
        logger.error("\(what, privacy: .public)：\(reason, privacy: .public) [\(String(describing: file), privacy: .public):\(line)]")
    }
}
