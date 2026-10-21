import Foundation

struct RefreshPlan: Equatable, Sendable {
    let date: Date
    let reason: String
}

struct RefreshRequest: Codable, Equatable, Sendable {
    var id = UUID()
    let requestedAt: Date
    let preferredDate: Date
    let reason: String
}

enum BackgroundRefreshPolicy {
    static let version = "opportunistic-refresh-4"
    static let cadence: TimeInterval = 15 * 60
    static let recoveryDelay: TimeInterval = 30 * 60

    static func plan(at now: Date, settings: Settings, context: ContextSnapshot?, prompts: [ExercisePrompt], calendar: Calendar = .current) -> RefreshPlan? {
        guard settings.monitoring else { return nil }
        let active = ReminderPlanning.active(at: now, settings: settings, calendar: calendar)
        if !active {
            guard settings.startMinuteOfDay != settings.endMinuteOfDay,
                  let next = calendar.nextDate(after: now, matching: DateComponents(hour: settings.startHour, minute: settings.startMinute ?? 0), matchingPolicy: .nextTime) else { return nil }
            return .init(date: next, reason: "active_hours_begin")
        }

        var candidates = [RefreshPlan(date: now.addingTimeInterval(cadence), reason: "regular_15_minute_check")]
        func consider(_ date: Date?, reason: String) {
            guard let date, date > now else { return }
            // Avoid rapid retry loops. These are wake requests, not guaranteed timers.
            candidates.append(.init(date: max(date, now.addingTimeInterval(60)), reason: reason))
        }
        if let context, (0...30 * 60).contains(now.timeIntervalSince(context.date)) {
            consider(context.busyUntil?.addingTimeInterval(120), reason: "busy_event_ends")
            let target = ReminderPlanning.inactivityTarget(settings: settings, context: context, history: prompts)
            if let inactivity = context.inactivityEstimate, inactivity < Double(target) {
                consider(context.date.addingTimeInterval((Double(target) - inactivity) * 60), reason: "inactivity_threshold")
            }
            consider(context.lastWorkoutEnd?.addingTimeInterval(3600), reason: "workout_recovery_ends")
        }
        for prompt in prompts where [.prepared, .scheduled].contains(prompt.status) {
            consider(prompt.plannedFor?.addingTimeInterval(-60), reason: "planned_reminder_revalidation")
            consider(prompt.expiresAt, reason: "invitation_expires")
        }
        if let context {
            var current = context
            current.date = now
            current.localHour = calendar.component(.hour, from: now)
            if !ReminderPlanning.hasReminderToday(prompts, context: current) {
                consider(ReminderPlanning.preferredTime(context: current, settings: settings, history: prompts)?.date, reason: "preferred_reminder_time")
            }
            if (0...30 * 60).contains(now.timeIntervalSince(context.date)) {
                for event in ReminderPlanning.busyIntervals(context: context) {
                    consider(event.end.addingTimeInterval(120), reason: "busy_event_ends")
                }
            }
        }
        consider(ReminderPlanning.cooldownEnd(settings: settings, history: prompts, at: now, calendar: calendar), reason: "cooldown_ends")
        return candidates.min { $0.date < $1.date }
    }

    static func shouldReplace(_ pending: RefreshRequest?, with plan: RefreshPlan, at now: Date) -> Bool {
        guard let pending else { return true }
        // A local marker is not proof that watchOS still has a scheduled request.
        // Allow normal OS delays, but repair a stuck chain on the next available wake.
        if now.timeIntervalSince(pending.preferredDate) >= recoveryDelay { return true }
        return plan.date < pending.preferredDate.addingTimeInterval(-30)
    }

    static func recoveredRequest(_ pending: RefreshRequest, plan: RefreshPlan, at now: Date) -> RefreshRequest {
        if pending.preferredDate > now { return pending }
        return .init(requestedAt: now, preferredDate: plan.date, reason: "recover_overdue_" + plan.reason)
    }

    static func consumes(_ pending: RefreshRequest?, callbackID: String?, at now: Date) -> Bool {
        guard let pending else { return false }
        if let callbackID { return callbackID == pending.id.uuidString }
        // A system-generated callback can omit userInfo. Preserve a newer future request.
        return pending.preferredDate <= now
    }
}
