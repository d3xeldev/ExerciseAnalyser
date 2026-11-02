import Foundation

nonisolated enum CompanionSummary {
    static func selectionCounts(in prompts: [ExercisePrompt], on day: Date, asOf now: Date, calendar: Calendar) -> CompanionSnapshot.EffortCounts {
        let efforts = prompts.compactMap { prompt -> Effort? in
            guard let selectedAt = prompt.respondedAt, selectedAt <= now,
                  calendar.isDate(selectedAt, inSameDayAs: day),
                  let id = prompt.selectedExerciseID else { return nil }
            return prompt.options.first { $0.id == id }?.exercise.effort
        }
        return .init(low: efforts.filter { $0 == .easy }.count,
                     moderate: efforts.filter { $0 == .moderate }.count,
                     high: efforts.filter { $0 == .challenge }.count)
    }

    // Count resolved misses from the full history, not the phone's latest 30 prompts.
    // Attribute them to the invitation day; active, cancelled and failed requests are not misses.
    static func missedCount(in prompts: [ExercisePrompt], on day: Date, asOf now: Date, calendar: Calendar) -> Int {
        prompts.filter { prompt in
            let invitedAt = prompt.notificationDate ?? prompt.createdAt
            return invitedAt <= now && calendar.isDate(invitedAt, inSameDayAs: day)
                && prompt.completedAt == nil && prompt.abandonedAt == nil
                && [.dismissed, .expired, .ignored].contains(prompt.status)
        }.count
    }
}
