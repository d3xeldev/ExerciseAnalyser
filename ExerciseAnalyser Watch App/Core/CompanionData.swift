import Foundation

// Bounded, read-only projection. The watch remains the owner of study records.
nonisolated struct CompanionSnapshot: Codable, Sendable {
    var schemaVersion = 1
    let generatedAt: Date
    let participantID: UUID
    let dataAvailable: Bool
    let monitoring: Bool
    let checkedAt: Date?
    let status: String
    let steps: Double?
    let heartRate: Double?
    let heartRateAt: Date?
    let exerciseMinutes: Double?
    let sleepHours: Double?
    let days: [Day]
    let prompts: [Prompt]
    let events: [Event]
    let permissions: [Detail]
    let preferences: [Detail]
    let issues: [String]
    let totalPrompts: Int
    let requestedNotifications: Int
    let completedBreaks: Int

    struct Day: Codable, Identifiable, Sendable {
        let date: Date
        let steps: Double?
        let low: Int
        let moderate: Int
        let high: Int
        var id: Date { date }
        var completed: Int { low + moderate + high }
    }

    struct Prompt: Codable, Identifiable, Sendable {
        let id: UUID
        let date: Date
        let outcome: String
        let method: String
        let isManual: Bool
        let options: [Option]
        let selectedTitle: String?
        let expiresAt: Date
    }

    struct Option: Codable, Identifiable, Sendable {
        let id: String
        let title: String
        let effort: String
        let minutes: Int
        let symbol: String
        let instructions: String
    }

    struct Event: Codable, Identifiable, Sendable {
        let id: UUID
        let date: Date
        let kind: String
        let source: String
    }

    struct Detail: Codable, Identifiable, Sendable {
        let title: String
        let value: String
        var id: String { title }
    }
}

nonisolated struct CompanionReminder: Codable, Sendable {
    let promptID: UUID
    let title: String
    let subtitle: String
    let body: String
    let dueAt: Date
    let expiresAt: Date
}

nonisolated struct CompanionPacket: Codable, Sendable {
    var schemaVersion = 1
    var id = UUID()
    var createdAt = Date()
    let payload: Payload

    enum Payload: Codable, Sendable {
        case reminder(CompanionReminder)
        case cancel([UUID])
        case snooze(CompanionSnooze)
        case requestSnapshot
        case requestExport
        case exportError(String)
    }
}

// Fast messages and background transfers can arrive twice or out of order.
// Persist this ledger only after the corresponding notification operation succeeds.
nonisolated struct CompanionReminderLedger: Codable {
    struct Entry: Codable {
        let version: Date
        let retainedUntil: Date
    }
    var entries: [String: Entry] = [:]

    func accepts(id: UUID, version: Date, expiresAt: Date, now: Date) -> Bool {
        guard expiresAt > now, version <= now.addingTimeInterval(60),
              now.timeIntervalSince(version) < 24 * 60 * 60 else { return false }
        return entries[id.uuidString].map { version > $0.version } ?? true
    }

    mutating func record(id: UUID, version: Date, now: Date) {
        entries = entries.filter { $0.value.retainedUntil > now }
        entries[id.uuidString] = Entry(version: version, retainedUntil: now.addingTimeInterval(25 * 60 * 60))
    }
}

nonisolated enum MovementNotification {
    static let categoryID = "movement.invitation"
    static let choose = "movement.choose"
    static let snoozeFive = "movement.snooze.5"
    static let snoozeTen = "movement.snooze.10"

    // iOS/watchOS use the same request identifier to coordinate the two local requests.
    static func requestID(_ promptID: UUID) -> String { promptID.uuidString }

    static func canRelay(_ reminder: CompanionReminder, at now: Date) -> Bool {
        // A late background transfer must not alert again after the watch's coordination window.
        reminder.expiresAt > now && reminder.dueAt < reminder.expiresAt && now.timeIntervalSince(reminder.dueAt) <= 10
    }
}

nonisolated struct CompanionSnooze: Codable, Sendable {
    let promptID: UUID
    let minutes: Int
    let expiresAt: Date

    func isValid(requestedAt: Date, now: Date) -> Bool {
        [5, 10].contains(minutes) && expiresAt > now && (0...60).contains(now.timeIntervalSince(requestedAt))
    }
}
