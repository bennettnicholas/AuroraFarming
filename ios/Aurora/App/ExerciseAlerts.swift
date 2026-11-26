import Foundation
import UserNotifications

/// Reminds you to set a temporary target in Trio when sustained exercise starts.
///
/// Runs after every sync (about every 5 minutes, also in the background). Over the
/// last `windowMinutes`, a minute counts as active when the ring's heart rate is at
/// or above `heartRateThreshold`, or (unless "heart rate only") its movement reaches
/// `metThreshold` MET. Exercise starts when `minutesNeeded` minutes are active, or
/// when the ring's own exercise-HR mode is measuring at a high heart rate. A flight
/// of stairs is one or two active minutes, so it does not trigger.
///
/// Reminder only: nothing is sent to Trio.
@MainActor
final class ExerciseAlerts {
    enum Key {
        static let enabled = "exercise.enabled"
        static let hr = "exercise.hrThreshold"
        static let met = "exercise.metThreshold"
        static let hrOnly = "exercise.hrOnly"
        static let minutes = "exercise.minutesNeeded"
        static let endNotice = "exercise.endNotice"
        static let inExercise = "exercise.state.active"
        static let lastAlert = "exercise.state.lastAlert"
        static let quiet = "exercise.state.quietChecks"
    }

    static let windowMinutes: UInt32 = 8
    static let cooldown: TimeInterval = 45 * 60

    private let defaults = UserDefaults.standard
    var isEnabled: Bool { defaults.bool(forKey: Key.enabled) }
    var heartRateThreshold: Double { defaults.object(forKey: Key.hr) as? Double ?? 120 }
    var metThreshold: Double { defaults.object(forKey: Key.met) as? Double ?? 5 }
    var heartRateOnly: Bool { defaults.bool(forKey: Key.hrOnly) }
    var minutesNeeded: Int { defaults.object(forKey: Key.minutes) as? Int ?? 5 }
    var endNotice: Bool { defaults.object(forKey: Key.endNotice) as? Bool ?? true }

    /// Evaluate after a sync. Returns a one-line decision for the sync history.
    func evaluate(store: AuroraStore, report: SyncReport) -> String? {
        guard isEnabled else { return nil }
        let check: ExerciseCheck
        do {
            check = try store.exerciseCheck(now: Date.now.timeIntervalSince1970,
                                            windowMinutes: Self.windowMinutes,
                                            hrThreshold: heartRateThreshold,
                                            metThreshold: heartRateOnly ? 1_000 : metThreshold)
        } catch {
            return "Exercise check failed: \(userMessage(for: error))"
        }
        let ringWorkout = report.exerciseMeasuring && Double(report.exerciseHeartRate ?? 0) >= heartRateThreshold
        let active = Int(check.activeMinutes) >= minutesNeeded || ringWorkout

        var line = "Exercise: \(check.activeMinutes)/\(check.windowMinutes) active min"
        if let hr = check.maxHeartRate { line += ", max HR \(Int(hr))" }
        if let bpm = report.exerciseHeartRate { line += ", ring workout HR \(bpm)" }
        if let newest = check.newestDataTs {
            let lag = Int((Date.now.timeIntervalSince1970 - newest) / 60)
            if lag >= 3 { line += ", data \(lag) min old" }
        }

        let inExercise = defaults.bool(forKey: Key.inExercise)
        if active {
            defaults.set(0, forKey: Key.quiet)
            if !inExercise {
                defaults.set(true, forKey: Key.inExercise)
                let last = defaults.object(forKey: Key.lastAlert) as? Date ?? .distantPast
                if Date.now.timeIntervalSince(last) >= Self.cooldown {
                    defaults.set(Date.now, forKey: Key.lastAlert)
                    Self.notify(title: "Exercise detected",
                                body: "Your heart rate has been up for a few minutes. Set a temp target in Trio?",
                                id: "exercise.start")
                    return line + " → started, reminder sent"
                }
                return line + " → started (reminder skipped, one was sent recently)"
            }
            return line + " → still exercising"
        }
        if inExercise {
            let quiet = defaults.integer(forKey: Key.quiet) + 1
            defaults.set(quiet, forKey: Key.quiet)
            if quiet >= 2 { // about 10 minutes calm
                defaults.set(false, forKey: Key.inExercise)
                defaults.set(0, forKey: Key.quiet)
                if endNotice {
                    Self.notify(title: "Exercise ended",
                                body: "Things have calmed down for about 10 minutes. Time to end the temp target in Trio?",
                                id: "exercise.end")
                    return line + " → ended, notice sent"
                }
                return line + " → ended"
            }
            return line + " → calming down"
        }
        return line + " → no exercise"
    }

    static func requestPermission() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .timeSensitive])) ?? false
    }

    /// A test notification in 5 seconds, so you can lock the phone and see it arrive.
    static func sendTest() {
        notify(title: "Exercise detected (test)",
               body: "This is how the reminder to set a temp target in Trio will look.",
               id: "exercise.test", delay: 5)
    }

    private static func notify(title: String, body: String, id: String, delay: TimeInterval = 1) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: delay, repeats: false)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
