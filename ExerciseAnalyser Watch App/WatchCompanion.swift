import Foundation

extension AppModel {
    func publishPhoneSnapshot() {
        let now = Date()
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let days: [CompanionSnapshot.Day] = (-6...0).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let completed = state.prompts.filter { $0.completedAt.map { calendar.isDate($0, inSameDayAs: day) && $0 <= now } ?? false }
            func count(_ effort: Effort) -> Int {
                completed.filter { prompt in prompt.options.first { $0.id == prompt.selectedExerciseID }?.exercise.effort == effort }.count
            }
            let recordedSteps = context?.stepHistory?.last { calendar.isDate($0.date, inSameDayAs: day) }?.value
            let currentSteps = context.flatMap { calendar.isDate($0.date, inSameDayAs: day) ? $0.stepsToday : nil }
            return .init(date: day, steps: currentSteps ?? recordedSteps, low: count(.easy), moderate: count(.moderate), high: count(.challenge))
        }
        let prompts: [CompanionSnapshot.Prompt] = state.prompts.suffix(30).reversed().map { prompt in
            .init(id: prompt.id, date: prompt.createdAt,
                  outcome: prompt.completedAt != nil ? "Completed" : prompt.abandonedAt != nil ? "Abandoned" : prompt.status.rawValue.capitalized,
                  method: prompt.method.title, isManual: prompt.isManual,
                  options: prompt.options.map { option in
                      .init(id: option.id, title: option.exercise.title, effort: option.exercise.effort.title,
                            minutes: option.exercise.minutes, symbol: option.exercise.symbol, instructions: option.exercise.instructions)
                  }, selectedTitle: prompt.options.first { $0.id == prompt.selectedExerciseID }?.exercise.title, expiresAt: prompt.expiresAt)
        }
        let preferences: [CompanionSnapshot.Detail] = [
            .init(title: "Active hours", value: String(format: "%02d:%02d–%02d:%02d", settings.startHour, settings.startMinute ?? 0, settings.endHour, settings.endMinute ?? 0)),
            .init(title: "Low movement", value: "\(settings.inactivityMinutes) minutes"),
            .init(title: "Reminder cooldown", value: "\(settings.cooldownMinutes) minutes"),
            .init(title: "Daily reminder limit", value: settings.dailyLimit == Settings.unlimitedDailyLimit ? "Unlimited" : String(settings.dailyLimit)),
            .init(title: "Exploration", value: "\(Int(settings.explorationRate * 100))%"),
            .init(title: "Calendars", value: settings.selectedCalendarIDs.map { "\($0.count) selected" } ?? "All calendars"),
            .init(title: "Enabled exercises", value: "\(Exercise.catalog.filter { !settings.excludedExerciseIDs.contains($0.id) }.count) of \(Exercise.catalog.count)")
        ]
        CompanionConnection.shared.publish(.init(generatedAt: now, participantID: state.participantID,
            dataAvailable: dataAvailable, monitoring: settings.monitoring, checkedAt: context?.date,
            status: decision?.reasons.joined(separator: " · ") ?? "Waiting for a watch check",
            steps: context?.stepsToday, heartRate: context?.heartRate?.value, heartRateAt: context?.heartRate?.date,
            exerciseMinutes: context?.exerciseMinutes, sleepHours: context?.sleepHours, days: days, prompts: prompts,
            events: state.events.suffix(40).reversed().map { .init(id: $0.id, date: $0.date, kind: $0.kind, source: $0.source) },
            permissions: [
                .init(title: "Health setup", value: healthConfigured ? "Configured; read access is private" : "Set up on watch"),
                .init(title: "Calendar", value: calendarAccess ? "Full access" : "Needs access on watch"),
                .init(title: "Motion", value: motionAccess ? "Authorized" : "Needs access on watch"),
                .init(title: "Watch notifications", value: notificationAccess ? "Enabled" : "Needs access on watch")
            ], preferences: preferences, issues: context?.issues ?? [], totalPrompts: state.prompts.count,
            requestedNotifications: state.prompts.filter { $0.notificationDate != nil && !$0.isManual }.count,
            completedBreaks: state.prompts.filter { $0.completedAt != nil }.count))
    }
}
