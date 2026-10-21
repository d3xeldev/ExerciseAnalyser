import Foundation

enum StepEvidence {
    static func stepsDuringEvent(_ event: DateInterval, samples: [(interval: DateInterval, steps: Double)]) -> Double? {
        let overlapping = samples.filter { $0.interval.start < event.end && $0.interval.end > event.start }
        guard !overlapping.isEmpty || samples.contains(where: { $0.interval.end <= event.start }) else { return nil }
        return overlapping.reduce(0) { $0 + $1.steps }
    }

    static func inferredEmptyRecentWindow(noData: Bool, sampleIntervals: [DateInterval], at now: Date) -> Bool {
        // Positive evidence of readable history is required. Denied/empty/failed history is never zero.
        noData && !sampleIntervals.isEmpty && sampleIntervals.allSatisfy { $0.end < now.addingTimeInterval(-15 * 60) }
    }
}

struct PlannedReminder: Equatable {
    let date: Date
    let freeMinutes: Double
    let reason: String
}

enum ReminderPlanning {
    static let policyVersion = "opportunity-4"

    static func calendar(for context: ContextSnapshot) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: context.timeZoneIdentifier) ?? .current
        return calendar
    }

    static func dueHistory(_ history: [ExercisePrompt], at now: Date) -> [ExercisePrompt] {
        history.filter { $0.notificationDate.map { $0 <= now } ?? false }
    }

    static func hasReminderToday(_ history: [ExercisePrompt], context: ContextSnapshot) -> Bool {
        let calendar = calendar(for: context)
        return dueHistory(history, at: context.date).contains { calendar.isDate($0.notificationDate!, inSameDayAs: context.date) }
    }

    // The first miss keeps the base delay; the second uses 1.5x, then 2.25x, 3.375x, etc.
    // Only today's consecutive misses affect backoff; the base cooldown can cross midnight.
    static func cooldownEnd(settings: Settings, history: [ExercisePrompt], at now: Date, calendar: Calendar) -> Date? {
        let sent = dueHistory(history, at: now).sorted { $0.notificationDate! > $1.notificationDate! }
        guard let last = sent.first?.notificationDate else { return nil }
        let today = sent.prefix { calendar.isDate($0.notificationDate!, inSameDayAs: now) }
        let misses = today.prefix { $0.status == .dismissed || $0.status == .ignored || $0.shouldIgnore(at: now) || $0.status == .expired || ($0.status == .scheduled && $0.expiresAt <= now) }.count
        let base = Double(max(0, settings.cooldownMinutes)) * 60
        let baseEnd = last.addingTimeInterval(base)
        guard misses >= 2, base > 0 else { return baseEnd }
        let midnight = calendar.dateInterval(of: .day, for: now)!.end
        let extended = last.addingTimeInterval(base * pow(1.5, Double(min(misses - 1, 100))))
        return max(baseEnd, min(midnight, extended))
    }

    static func preferredTime(context: ContextSnapshot, settings: Settings, history: [ExercisePrompt]) -> PlannedReminder? {
        let calendar = calendar(for: context)
        let today = calendar.startOfDay(for: context.date)
        let weekday = calendar.component(.weekday, from: context.date)
        let resolved = dueHistory(history, at: context.date).filter {
            $0.notificationDate! < today && (($0.selectedExerciseID != nil && $0.status != .ignored) || $0.status == .dismissed || $0.status == .ignored || $0.status == .expired)
        }
        // Use the local time at delivery, not the time an earlier plan was created.
        func localCalendar(_ prompt: ExercisePrompt) -> Calendar { Self.calendar(for: prompt.context) }
        let sameWeekday = resolved.filter { localCalendar($0).component(.weekday, from: $0.notificationDate!) == weekday }
        let groups = Dictionary(grouping: sameWeekday) { localCalendar($0).component(.hour, from: $0.notificationDate!) }
        let reliable = groups.filter { _, prompts in
            let accepted = prompts.filter { ($0.selectedExerciseID != nil && $0.status != .ignored) }
            let days = Set(accepted.map { localCalendar($0).startOfDay(for: $0.notificationDate!) })
            return days.count >= 2 && accepted.count * 2 > prompts.count
        }
        let hour = reliable.keys.sorted { lhs, rhs in
            let left = reliable[lhs]!, right = reliable[rhs]!
            let leftRate = Double(left.filter { ($0.selectedExerciseID != nil && $0.status != .ignored) }.count + 1) / Double(left.count + 2)
            let rightRate = Double(right.filter { ($0.selectedExerciseID != nil && $0.status != .ignored) }.count + 1) / Double(right.count + 2)
            return leftRate == rightRate ? lhs < rhs : leftRate > rightRate
        }.first
        var components: DateComponents
        let reason: String
        if let hour {
            components = DateComponents(hour: hour, minute: 0)
            reason = "learned_weekday_hour"
        } else {
            // Fall back only without any resolved history for this weekday.
            guard sameWeekday.isEmpty, let yesterday = calendar.date(byAdding: .day, value: -1, to: today),
                  let accepted = resolved.filter({ ($0.selectedExerciseID != nil && $0.status != .ignored) && $0.notificationDate! >= yesterday })
                    .max(by: { $0.notificationDate! < $1.notificationDate! }) else { return nil }
            components = localCalendar(accepted).dateComponents([.hour, .minute], from: accepted.notificationDate!)
            reason = "previous_day_accepted_time"
        }
        guard let date = calendar.date(bySettingHour: components.hour!, minute: components.minute!, second: 0, of: today),
              active(at: date, settings: settings, calendar: calendar) else { return nil }
        return .init(date: date, freeMinutes: freeMinutes(at: date, context: context, settings: settings), reason: reason)
    }

    static func busyIntervals(context: ContextSnapshot) -> [DateInterval] {
        var merged: [DateInterval] = []
        for interval in (context.busyIntervals ?? []).sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, last.end >= interval.start {
                merged[merged.count - 1] = .init(start: last.start, end: max(last.end, interval.end))
            } else { merged.append(interval) }
        }
        return merged
    }

    static func recentBusyEvent(context: ContextSnapshot) -> DateInterval? {
        busyIntervals(context: context).last { $0.end <= context.date && context.date.timeIntervalSince($0.end) < 15 * 60 }
    }

    static func postEventSteps(context: ContextSnapshot) -> Double? {
        guard let event = recentBusyEvent(context: context), context.lastBusyEventActivity?.interval == event else { return nil }
        return context.lastBusyEventActivity?.steps
    }

    static func inactivityTarget(settings: Settings, context: ContextSnapshot, history: [ExercisePrompt]) -> Int {
        let minutesIntoWindow = (context.localHour * 60 + calendar(for: context).component(.minute, from: context.date) - settings.startMinuteOfDay + 1440) % 1440
        return !hasReminderToday(history, context: context) && minutesIntoWindow >= 120 ? min(15, settings.inactivityMinutes) : settings.inactivityMinutes
    }

    static func active(at date: Date, settings: Settings, calendar: Calendar) -> Bool {
        settings.isActive(hour: calendar.component(.hour, from: date), minute: calendar.component(.minute, from: date))
    }

    static func freeMinutes(at date: Date, context: ContextSnapshot, settings: Settings) -> Double {
        guard context.calendarAvailable, let intervals = context.busyIntervals else { return 0 }
        let calendar = calendar(for: context)
        guard active(at: date, settings: settings, calendar: calendar),
              !intervals.contains(where: { $0.start <= date && date < $0.end }) else { return 0 }
        let quietStart = calendar.nextDate(after: date, matching: DateComponents(hour: settings.endHour, minute: settings.endMinute ?? 0), matchingPolicy: .nextTime) ?? date
        let midnight = calendar.dateInterval(of: .day, for: date)!.end
        let nextBusy = intervals.filter { $0.start > date }.map(\.start).min() ?? quietStart
        return max(0, min(quietStart, midnight, nextBusy).timeIntervalSince(date) / 60)
    }

}
