import Foundation

/// The collapsed card's header timestamp, worded like a system banner's:
/// "刚刚" while the push is fresh, then minutes, then hours, then a date.
/// Pure so the wording boundaries are testable without a view.
enum RelativeTime {
    static func describe(_ date: Date, now: Date) -> String {
        let elapsed = now.timeIntervalSince(date)
        // A timestamp in the future (clock skew) reads as fresh, never negative.
        if elapsed < 45 { return "刚刚" }
        if elapsed < 3600 { return "\(max(1, Int(elapsed / 60))) 分钟前" }
        if elapsed < 86400 { return "\(Int(elapsed / 3600)) 小时前" }
        let day = Calendar.current.component(.day, from: date)
        let month = Calendar.current.component(.month, from: date)
        return "\(month)月\(day)日"
    }
}
