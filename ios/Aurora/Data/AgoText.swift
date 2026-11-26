import Foundation

/// "just now", "4 min ago", "at 9:23 PM", or "Nov 25, 9:23 PM". Views that show it
/// wrap it in a `TimelineView` so it keeps counting while the screen stays open.
func agoText(_ date: Date, now: Date = .now) -> String {
    let seconds = now.timeIntervalSince(date)
    if seconds < 60 { return "just now" }
    if seconds < 60 * 60 { return "\(Int(seconds / 60)) min ago" }
    if Calendar.current.isDate(date, inSameDayAs: now) {
        return "at \(date.formatted(date: .omitted, time: .shortened))"
    }
    return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
}
