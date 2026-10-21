import Foundation

enum ComplicationKind: String, CaseIterable, Sendable {
    case moment = "MoveMoment.Status"
    case activity = "MoveMoment.Activity"
    case breaks = "MoveMoment.Breaks"

    var destination: String {
        switch self {
        case .moment: "moment"
        case .activity: "activity"
        case .breaks: "breaks"
        }
    }

    var url: URL { URL(string: "movemoment://\(destination)")! }
}

// Only this minimal snapshot is shared with the WidgetKit extension. The study database remains private to the app.
struct ComplicationSnapshot: Codable, Equatable, Sendable {
    static let appGroup = "group.com.d3xel.ExerciseAnalyser"
    static let freshness: TimeInterval = 30 * 60

    var schemaVersion = 1
    var generatedAt: Date
    var monitoring: Bool
    var dataAvailable = true
    var checkedAt: Date?
    var statusDetail = "Waiting for an opportunity"
    var lowMovementMinutes: Double?
    var inactivityTarget = 30
    var steps: Double?
    var exerciseMinutes: Double?
    var completedToday = 0
    var invitationExpiresAt: Date?
    var activeExerciseTitle: String?
    var activeExerciseExpiresAt: Date?
    var invitationStartsAt: Date?
    var effortCompletions: [EffortCompletion]?

    var stepHistory: [DailyTotal]?
    var breakCompletions: [Date]?

    struct DailyTotal: Codable, Equatable, Identifiable, Sendable {
        let date: Date
        let value: Double?
        var id: Date { date }
    }

    func weeklyStepDays(at now: Date, calendar: Calendar = .current) -> [DailyTotal] {
        dailyEffortCounts(at: now, calendar: calendar).map { day in
            let recorded = dataAvailable ? stepHistory?.last {
                calendar.isDate($0.date, inSameDayAs: day.date) && $0.date <= now
            } : nil
            let currentSteps = dataAvailable && checkedAt.map {
                $0 <= now && calendar.isDate($0, inSameDayAs: day.date)
            } == true ? steps : nil
            return DailyTotal(date: day.date, value: recorded?.value ?? currentSteps)
        }
    }

    func weeklyBreakDays(at now: Date, calendar: Calendar = .current) -> [DailyTotal] {
        let dates = breakCompletions ?? effortCompletions?.map(\.date) ?? []
        return dailyEffortCounts(at: now, calendar: calendar).map { day in
            let count = dates.filter { $0 <= now && calendar.isDate($0, inSameDayAs: day.date) }.count
            return DailyTotal(date: day.date, value: dataAvailable ? Double(count) : nil)
        }
    }

    struct EffortCompletion: Codable, Equatable, Sendable {
        let date: Date
        let effort: String
    }

    func weeklyEffortCounts(at now: Date, calendar: Calendar = .current) -> [Int] {
        guard dataAvailable, let start = calendar.date(byAdding: .day, value: -7, to: now) else { return [0, 0, 0] }
        let completions = (effortCompletions ?? []).filter { $0.date > start && $0.date <= now }
        return ["easy", "moderate", "challenge"].map { effort in
            completions.filter { $0.effort == effort }.count
        }
    }

    struct EffortDay: Identifiable, Equatable, Sendable {
        let date: Date
        let counts: [Int]
        var id: Date { date }
    }

    func dailyEffortCounts(at now: Date, calendar: Calendar = .current) -> [EffortDay] {
        let today = calendar.startOfDay(for: now)
        return (-6...0).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let end = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            let completions = dataAvailable ? (effortCompletions ?? []).filter {
                $0.date >= day && $0.date < end && $0.date <= now
            } : []
            return EffortDay(date: day, counts: ["easy", "moderate", "challenge"].map { effort in
                completions.filter { $0.effort == effort }.count
            })
        }
    }

    static func empty(at date: Date) -> Self {
        .init(generatedAt: date, monitoring: false, dataAvailable: false, statusDetail: "Open Move Moment to set up")
    }

    func isFresh(at now: Date) -> Bool {
        guard let checkedAt else { return false }
        return (0..<Self.freshness).contains(now.timeIntervalSince(checkedAt))
    }

    func hasCurrentActivity(at now: Date, calendar: Calendar = .current) -> Bool {
        guard let checkedAt else { return false }
        return isFresh(at: now) && calendar.isDate(checkedAt, inSameDayAs: now)
    }

    func completions(at now: Date, calendar: Calendar = .current) -> Int? {
        guard dataAvailable, calendar.isDate(generatedAt, inSameDayAs: now), now >= generatedAt else { return nil }
        return completedToday
    }

    func invitationAvailable(at now: Date) -> Bool {
        monitoring && dataAvailable && now >= generatedAt && now >= (invitationStartsAt ?? generatedAt) && (invitationExpiresAt.map { $0 > now } ?? false)
    }

    func hasActiveExercise(at now: Date) -> Bool {
        activeExerciseTitle != nil && now < (activeExerciseExpiresAt ?? generatedAt.addingTimeInterval(10 * 60))
    }

    func title(at now: Date) -> String {
        guard dataAvailable else { return "Open to set up" }
        if hasActiveExercise(at: now) { return "Your movement break" }
        guard monitoring else { return "Paused" }
        if invitationAvailable(at: now) { return "Choose a break" }
        if let invitationStartsAt, invitationStartsAt > now { return "Break planned" }
        return isFresh(at: now) ? "Watching for a moment" : "Awaiting an update"
    }

    func detail(at now: Date) -> String {
        if let activeExerciseTitle, hasActiveExercise(at: now) { return activeExerciseTitle }
        if invitationAvailable(at: now) { return "Low · Moderate · High" }
        if !monitoring { return dataAvailable ? "Monitoring is off" : statusDetail }
        if let invitationStartsAt, invitationStartsAt > now {
            return "Reminder at \(invitationStartsAt.formatted(date: .omitted, time: .shortened))"
        }
        return isFresh(at: now) ? statusDetail : "Background checks are automatic"
    }

    func transitionDates(after now: Date, calendar: Calendar = .current) -> [Date] {
        var dates: [Date] = []
        if activeExerciseTitle != nil { dates.append(activeExerciseExpiresAt ?? generatedAt.addingTimeInterval(10 * 60)) }
        if let checkedAt { dates.append(checkedAt.addingTimeInterval(Self.freshness)) }
        if let invitationExpiresAt { dates.append(invitationExpiresAt) }
        if let invitationStartsAt { dates.append(invitationStartsAt) }
        for completion in effortCompletions ?? [] {
            if let expiry = calendar.date(byAdding: .day, value: 7, to: completion.date) { dates.append(expiry) }
        }
        if let midnight = calendar.dateInterval(of: .day, for: now)?.end { dates.append(midnight) }
        return Array(Set(dates.filter { $0 > now })).sorted()
    }
}

enum ComplicationCache {
    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ComplicationSnapshot.appGroup)?
            .appendingPathComponent("complication-snapshot.json")
    }

    static func read(from url: URL?) -> ComplicationSnapshot? {
        guard let url, let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(ComplicationSnapshot.self, from: data), snapshot.schemaVersion == 1 else { return nil }
        return snapshot
    }

    static func write(_ snapshot: ComplicationSnapshot, to url: URL) throws {
        let data = try JSONEncoder().encode(snapshot)
        #if os(watchOS) || os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}
