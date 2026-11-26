import Foundation
import Observation

/// What started a sync, shown in the sync history.
enum SyncTrigger: String, Codable {
    case manual = "You tapped sync"
    case appOpen = "App opened"
    case foregroundTimer = "Every 5 min (app open)"
    case backgroundWake = "Background (ring wake)"
    case backgroundRefresh = "Background refresh"
}

struct SyncRecord: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var trigger: SyncTrigger
    var ok: Bool
    /// New ring events on success, or the error.
    var detail: String
    /// Nocturne's result for this sync, nil when Nocturne is off.
    var nocturne: String?
    var wasInBackground: Bool
    /// The exercise detector's decision after this sync, when alerts are on.
    var exercise: String? = nil
}

/// The last syncs, kept across launches, so you can check the background cadence.
@MainActor
@Observable
final class SyncHistory {
    private(set) var records: [SyncRecord] = []
    /// When the next background wake was asked for.
    private(set) var nextWakeAt: Date?

    private let key = "aurora.sync.history"
    private let nextKey = "aurora.sync.nextWake"
    private let limit = 200

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONDecoder().decode([SyncRecord].self, from: data) {
            records = saved
        }
        nextWakeAt = UserDefaults.standard.object(forKey: nextKey) as? Date
    }

    func add(_ record: SyncRecord) {
        records.insert(record, at: 0)
        if records.count > limit { records.removeLast(records.count - limit) }
        if let data = try? JSONEncoder().encode(records) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func setNextWake(_ date: Date?) {
        nextWakeAt = date
        UserDefaults.standard.set(date, forKey: nextKey)
    }

    func clear() {
        records = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}
