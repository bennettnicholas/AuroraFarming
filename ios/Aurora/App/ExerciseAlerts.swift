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
        static let quiet = "exercise.state.calmSince"
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

    /// The watch drives the reminder while it is sending heart rate.
    weak var watch: HeartRateMonitor?
    /// Called with a line for the sync history when the watch starts or ends an exercise.
    var onWatchDecision: ((String) -> Void)?
    private var lastWatchCheck = Date.distantPast

    /// Evaluate after a sync. Returns a one-line decision for the sync history.
    func evaluate(store: AuroraStore, report: SyncReport) -> String? {
        guard isEnabled else { return nil }
        if let watch, watch.isLive {
            return "Exercise: following watch heart rate (\(watch.latestBPM ?? 0) bpm now)"
        }
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

        var line = "Exercise (ring): \(check.activeMinutes)/\(check.windowMinutes) active min"
        if let hr = check.maxHeartRate { line += ", max HR \(Int(hr))" }
        if let bpm = report.exerciseHeartRate { line += ", ring workout HR \(bpm)" }
        if let newest = check.newestDataTs {
            let lag = Int((Date.now.timeIntervalSince1970 - newest) / 60)
            if lag >= 3 { line += ", data \(lag) min old" }
        }
        return line + " → " + decide(active: active)
    }

    /// Watch path: called for every watch reading, evaluated at most every 20 s.
    /// Minutes are active when the watch's median heart rate that minute reaches the
    /// threshold (movement isn't available from the watch broadcast).
    func watchReading() {
        guard isEnabled, let watch, Date.now.timeIntervalSince(lastWatchCheck) >= 20 else { return }
        lastWatchCheck = .now
        let medians = watch.minuteMedians(Int(Self.windowMinutes))
        let activeCount = medians.compactMap { $0 }.filter { $0 >= heartRateThreshold }.count
        let wasIn = defaults.bool(forKey: Key.inExercise)
        let decision = decide(active: activeCount >= minutesNeeded)
        if defaults.bool(forKey: Key.inExercise) != wasIn {
            let maxHR = medians.compactMap { $0 }.max().map { ", max HR \(Int($0))" } ?? ""
            onWatchDecision?("Exercise (watch): \(activeCount)/\(Self.windowMinutes) active min\(maxHR) → \(decision)")
        }
    }

    /// The start/end state machine shared by the ring and watch paths.
    private func decide(active: Bool) -> String {
        let inExercise = defaults.bool(forKey: Key.inExercise)
        if active {
            defaults.removeObject(forKey: Key.quiet)
            guard !inExercise else { return "still exercising" }
            defaults.set(true, forKey: Key.inExercise)
            let last = defaults.object(forKey: Key.lastAlert) as? Date ?? .distantPast
            guard Date.now.timeIntervalSince(last) >= Self.cooldown else {
                return "started (reminder skipped, one was sent recently)"
            }
            defaults.set(Date.now, forKey: Key.lastAlert)
            Self.notify(title: "Exercise detected",
                        body: "Your heart rate has been up for a few minutes. Set a temp target in Trio?",
                        id: "exercise.start")
            return "started, reminder sent"
        }
        guard inExercise else { return "no exercise" }
        // Ends after about 10 calm minutes.
        let calmSince = defaults.object(forKey: Key.quiet) as? Date ?? {
            defaults.set(Date.now, forKey: Key.quiet)
            return Date.now
        }()
        guard Date.now.timeIntervalSince(calmSince) >= 9 * 60 else { return "calming down" }
        defaults.set(false, forKey: Key.inExercise)
        defaults.removeObject(forKey: Key.quiet)
        guard endNotice else { return "ended" }
        Self.notify(title: "Exercise ended",
                    body: "Things have been calm for about 10 minutes. Time to end the temp target in Trio?",
                    id: "exercise.end")
        return "ended, notice sent"
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
