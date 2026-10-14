import Foundation

enum OpportunityEngine {
    static func evaluate(_ context: ContextSnapshot, settings: Settings, history: [ExercisePrompt]) -> OpportunityDecision {
        let now = context.date
        let firstToday = !ReminderPlanning.hasReminderToday(history, context: context)
        let inactivityTarget = ReminderPlanning.inactivityTarget(settings: settings, context: context, history: history)
        var reasons: [String] = []
        let free = context.busyIntervals == nil ? (context.freeMinutes ?? 15) : ReminderPlanning.freeMinutes(at: now, context: context, settings: settings)
        if !settings.monitoring { reasons.append("Monitoring is paused") }
        let inHours = settings.startHour < settings.endHour
            ? (settings.startHour..<settings.endHour).contains(context.localHour)
            : context.localHour >= settings.startHour || context.localHour < settings.endHour
        if !inHours || settings.startHour == settings.endHour { reasons.append("Quiet hours") }
        if !context.calendarAvailable { reasons.append("Calendar availability is unknown") }
        if context.busy || ReminderPlanning.busyIntervals(context: context).contains(where: { $0.start <= now && now < $0.end }) { reasons.append("A busy calendar event is in progress") }
        if free < 7 { reasons.append("Less than 7 minutes before the next busy event") }
        if context.charging { reasons.append("Watch is charging") }
        if let battery = context.batteryLevel, battery < 0.15 { reasons.append("Watch battery is low") }
        if context.lowPower { reasons.append("Low Power Mode is on") }
        if [.automotive, .running, .cycling, .walking].contains(context.motion) {
            reasons.append("Movement or travel is in progress")
        }
        if let steps = context.stepsRecent, steps >= 100 { reasons.append("Recent walking detected") }
        if let end = context.lastWorkoutEnd, now.timeIntervalSince(end) < 60 * 60 {
            reasons.append("A workout ended within the last hour")
        }
        if let hr = context.heartRate, hr.fresh(at: now, within: 20 * 60) {
            let resting = context.restingHeartRate.flatMap { $0.fresh(at: now, within: 7 * 86400) ? $0.value : nil }
            if hr.value > max(100, (resting ?? 70) + 30) { reasons.append("Heart rate suggests waiting") }
        }
        if let sleep = context.sleepHours, sleep < 4 { reasons.append("Recorded sleep was short; allow recovery") }
        let recentEvent = ReminderPlanning.recentBusyEvent(context: context)
        let eventSteps = ReminderPlanning.postEventSteps(context: context)
        if let recentEvent {
            if now < recentEvent.end.addingTimeInterval(120) { reasons.append("Waiting two minutes after the busy event") }
            if eventSteps == nil { reasons.append("Movement during the busy event is unknown") }
            else if eventSteps! >= 100 { reasons.append("Movement threshold reached during the busy event") }
        }
        let postEventOpportunity = recentEvent != nil && eventSteps.map { $0 < 100 } == true
        if firstToday, let preferred = ReminderPlanning.preferredTime(context: context, settings: settings, history: history), now < preferred.date {
            reasons.append("Waiting for the preferred reminder time")
        }
        if let inactivity = context.inactivityEstimate {
            if !postEventOpportunity && inactivity < Double(inactivityTarget) { reasons.append("Not enough sustained inactivity yet") }
        } else {
            reasons.append("Not enough fresh activity evidence")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: context.timeZoneIdentifier) ?? .current
        let sent = ReminderPlanning.dueHistory(history, at: now)
        if settings.dailyLimit != Settings.unlimitedDailyLimit,
           sent.filter({ calendar.isDate($0.notificationDate!, inSameDayAs: now) }).count >= settings.dailyLimit {
            reasons.append("Daily reminder limit reached")
        }
        if let end = ReminderPlanning.cooldownEnd(settings: settings, history: history, at: now, calendar: calendar), now < end {
            reasons.append("Reminder cooldown is active")
        }
        if history.contains(where: { $0.status == .selected && $0.completedAt == nil && $0.abandonedAt == nil }) {
            reasons.append("An exercise is awaiting feedback")
        }
        if history.contains(where: { [.prepared, .scheduled].contains($0.status) && ($0.plannedFor ?? $0.createdAt) <= now && $0.expiresAt > now }) {
            reasons.append("A movement invitation is already available")
        }
        guard reasons.isEmpty else {
            return .init(shouldNotify: false, score: 0, reasons: reasons, availableMinutes: free, inactivityMinutes: context.inactivityEstimate)
        }

        var contributions: [String: Double] = ["baseline": 60]
        if firstToday { contributions["first_daily_reminder"] = 10 }
        if (context.inactivityEstimate ?? 0) >= Double(settings.inactivityMinutes + 15) { contributions["prolonged_inactivity"] = 10 }
        if free >= 15 { contributions["free_window"] = 10 }
        if let minutes = context.exerciseMinutes, minutes < 30 { contributions["exercise_today"] = 5 }
        if let energy = context.activeEnergy, energy < 200 { contributions["energy_today"] = 3 }
        if let steps = context.stepsToday, steps < 4000 { contributions["steps_today"] = 3 }
        if let stand = context.standMinutes, stand < 30 { contributions["standing_today"] = 2 }
        if let distance = context.distanceMeters, distance < 2000 { contributions["distance_today"] = 2 }
        if let hrv = context.heartRateVariability, hrv.fresh(at: now, within: 86400),
           let baseline = context.hrvBaseline, baseline > 0, hrv.value < baseline * 0.65 { contributions["hrv_recovery"] = -10 }
        if let sleep = context.sleepHours, sleep < 6 { contributions["sleep_recovery"] = -5 }
        // Learn the actual delivery weekday/hour; future plans are not exposures.
        let similar = sent.filter {
            let local = ReminderPlanning.calendar(for: $0.context)
            return local.component(.weekday, from: $0.notificationDate!) == calendar.component(.weekday, from: now)
                && local.component(.hour, from: $0.notificationDate!) == context.localHour
                && ($0.selectedExerciseID != nil || $0.status == .dismissed || $0.status == .expired)
        }
        let accepted = similar.filter { $0.selectedExerciseID != nil }.count
        let acceptance = Double(accepted + 2) / Double(similar.count + 4)
        contributions["learned_receptivity"] = (acceptance - 0.5) * 20
        let score = contributions.values.reduce(0, +)
        return .init(shouldNotify: score >= 60, score: min(100, max(0, score)),
                     reasons: [score >= 60 ? (firstToday ? "First daily opportunity: low movement and time for a break" : "Sustained low movement and time for a break") : "Waiting for a better opportunity"], availableMinutes: free,
                     inactivityMinutes: context.inactivityEstimate, scoreContributions: contributions)
    }
}

enum RecommendationEngine {
    static let policyVersion = "epsilon-greedy-1"

    static func makePrompt<R: RandomNumberGenerator>(context: ContextSnapshot, decision: OpportunityDecision,
                                                     settings: Settings, history: [ExercisePrompt], randomizationSeed: String? = nil,
                                                     plannedFor: Date? = nil, deliveryReason: String? = nil, rng: inout R) -> ExercisePrompt? {
        guard decision.shouldNotify else { return nil }
        let exposures = ReminderPlanning.dueHistory(history, at: context.date)
        let epsilon = min(1, max(0, settings.explorationRate))
        let cold = exposures.allSatisfy { $0.selectedExerciseID == nil }
        let explore = cold || Double.random(in: 0..<1, using: &rng) < epsilon
        let method: SelectionMethod = cold ? .coldStartRandom : (explore ? .randomExploration : .learned)
        var options: [ExerciseOption] = []
        for effort in Effort.allCases {
            let candidates = Exercise.catalog.filter {
                $0.effort == effort && Double($0.minutes + 2) <= decision.availableMinutes && !settings.excludedExerciseIDs.contains($0.id)
            }
            guard !candidates.isEmpty else { return nil }
            var scores: [String: Double] = [:]
            var exposureCounts: [String: Int] = [:]
            var selectionCounts: [String: Int] = [:]
            for candidate in candidates {
                let shown = exposures.filter { $0.options.contains { $0.id == candidate.id } }.count
                let chosen = exposures.filter { $0.selectedExerciseID == candidate.id }.count
                scores[candidate.id] = Double(chosen + 1) / Double(shown + 2)
                exposureCounts[candidate.id] = shown
                selectionCounts[candidate.id] = chosen
            }
            // Uniform exploration deliberately does not use preference history.
            let best = scores.values.max() ?? 0
            let pool = explore ? candidates : candidates.filter { abs((scores[$0.id] ?? 0) - best) < 0.000001 }
            let choice = pool[Int.random(in: 0..<pool.count, using: &rng)]
            options.append(.init(exercise: choice, method: method, candidateIDs: candidates.map(\.id),
                                 preferenceScores: scores, selectionProbability: 1 / Double(pool.count),
                                 exposureCounts: exposureCounts, selectionCounts: selectionCounts))
        }
        return .init(id: UUID(), createdAt: context.date,
                     expiresAt: (plannedFor ?? context.date).addingTimeInterval(min(10, max(1, decision.availableMinutes - 5)) * 60),
                     context: context, decision: decision, settings: settings, policyVersion: policyVersion,
                     method: method, methodProbability: cold ? 1 : (explore ? epsilon : 1 - epsilon), options: options,
                     randomizationSeed: randomizationSeed, plannedFor: plannedFor, deliveryReason: deliveryReason)
    }
}

// Store a per-invitation seed for policy replay; system entropy generates each seed.
// The seed is exported as a decimal string to avoid precision loss in analysis tools.
struct StudyRandom: RandomNumberGenerator {
    var seed: UInt64

    mutating func next() -> UInt64 {
        seed &+= 0x9E3779B97F4A7C15
        var value = seed
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}
