import XCTest
@testable import ExerciseAnalyserCore

final class ReminderPlanningTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_626_400)

    var settings: Settings {
        var settings = Settings()
        settings.monitoring = true
        return settings
    }

    var context: ContextSnapshot {
        var context = ContextSnapshot(date: now, timeZoneIdentifier: "UTC", localHour: 14)
        context.calendarAvailable = true
        context.busyIntervals = []
        context.freeMinutes = 60
        context.heartRate = .init(value: 65, date: now)
        context.motion = .stationary
        context.motionObservedAt = now
        context.stationaryMinutes = 20
        return context
    }

    func plannedPrompt(_ context: ContextSnapshot, plan: PlannedReminder) -> ExercisePrompt {
        var rng = StudyRandom(seed: 1)
        var prompt = RecommendationEngine.makePrompt(context: context,
            decision: .init(shouldNotify: true, score: 60, reasons: [], availableMinutes: plan.freeMinutes),
            settings: settings, history: [], plannedFor: plan.date, deliveryReason: plan.reason, rng: &rng)!
        prompt.status = .scheduled
        prompt.scheduledAt = now
        return prompt
    }

    func testUserDelayPreservesExercisesAndFullResponseWindow() throws {
        for minutes in [5, 10] {
            var prompt = plannedPrompt(context, plan: .init(date: now, freeMinutes: 60, reason: "test"))
            let options = prompt.options.map(\.id)
            let window = prompt.expiresAt.timeIntervalSince(now)
            let tappedAt = now.addingTimeInterval(90)
            try prompt.snooze(minutes: minutes, at: tappedAt)
            let due = tappedAt.addingTimeInterval(Double(minutes) * 60)
            XCTAssertEqual(prompt.snoozedUntil, due)
            XCTAssertEqual(prompt.expiresAt, due.addingTimeInterval(window))
            XCTAssertEqual(prompt.options.map(\.id), options)
            XCTAssertFalse(prompt.isAvailable(at: due.addingTimeInterval(-1)))
            XCTAssertTrue(prompt.isAvailable(at: due))
            var waitingContext = context
            waitingContext.date = tappedAt
            XCTAssertTrue(OpportunityEngine.evaluate(waitingContext, settings: settings, history: [prompt])
                .reasons.contains("A movement invitation has been delayed"))
            let restored = try JSONDecoder().decode(ExercisePrompt.self, from: JSONEncoder().encode(prompt))
            XCTAssertEqual(restored.snoozedUntil, due)
            XCTAssertFalse(restored.isAvailable(at: tappedAt))
            try prompt.snooze(minutes: minutes, at: due)
            XCTAssertEqual(prompt.snoozedUntil, due.addingTimeInterval(Double(minutes) * 60))
            XCTAssertEqual(prompt.expiresAt.timeIntervalSince(prompt.snoozedUntil!), window)
        }
    }

    func testUserDelayRejectsEarlyDuplicateExpiredAndInvalidActions() throws {
        var prompt = plannedPrompt(context, plan: .init(date: now, freeMinutes: 60, reason: "test"))
        XCTAssertThrowsError(try prompt.snooze(minutes: 1, at: now))
        XCTAssertThrowsError(try prompt.snooze(minutes: 5, at: prompt.expiresAt))
        try prompt.snooze(minutes: 5, at: now)
        XCTAssertThrowsError(try prompt.snooze(minutes: 10, at: now.addingTimeInterval(1)))
        prompt.status = .selected
        XCTAssertThrowsError(try prompt.snooze(minutes: 5, at: now.addingTimeInterval(300)))
    }

    func testDelayedPromptSurvivesOriginalExpiryAndRejectsEarlySelection() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("study.json")
        let store = try StudyStore(url: url)
        var prompt = plannedPrompt(context, plan: .init(date: now, freeMinutes: 60, reason: "test"))
        let originalExpiry = prompt.expiresAt
        try prompt.snooze(minutes: 10, at: now.addingTimeInterval(60))
        try store.transaction { $0.prompts.append(prompt) }
        let restored = try StudyStore(url: url)
        try restored.expire(at: originalExpiry)
        XCTAssertEqual(restored.state.prompts[0].status, .scheduled)
        XCTAssertThrowsError(try restored.respond(promptID: prompt.id, exerciseID: prompt.options[0].id,
                                                  source: "notification", at: prompt.snoozedUntil!.addingTimeInterval(-1)))
        XCTAssertTrue(try restored.respond(promptID: prompt.id, exerciseID: prompt.options[0].id,
                                          source: "notification", at: prompt.snoozedUntil!))
    }

    func testEmptyStepWindowRequiresReadableOlderHistoryAndNoRecentOverlap() {
        let old = DateInterval(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(-1800))
        XCTAssertTrue(StepEvidence.inferredEmptyRecentWindow(noData: true, sampleIntervals: [old], at: now))
        XCTAssertFalse(StepEvidence.inferredEmptyRecentWindow(noData: false, sampleIntervals: [old], at: now))
        XCTAssertFalse(StepEvidence.inferredEmptyRecentWindow(noData: true, sampleIntervals: [], at: now))
        let overlap = DateInterval(start: now.addingTimeInterval(-1200), end: now.addingTimeInterval(-600))
        XCTAssertFalse(StepEvidence.inferredEmptyRecentWindow(noData: true, sampleIntervals: [old, overlap], at: now))
    }

    func testFirstDailyPriorityDoesNotBypassCalendarWearOrMovementEvidence() {
        XCTAssertEqual(Settings().inactivityMinutes, 30)
        XCTAssertEqual(Settings().cooldownMinutes, 60)
        XCTAssertTrue(OpportunityEngine.evaluate(context, settings: settings, history: []).shouldNotify)
        var morning = context
        morning.localHour = settings.startHour + 1
        XCTAssertFalse(OpportunityEngine.evaluate(morning, settings: settings, history: []).shouldNotify)
        var missing = context
        missing.heartRate = nil
        XCTAssertFalse(OpportunityEngine.evaluate(missing, settings: settings, history: []).shouldNotify)
        var busy = context
        busy.busy = true
        XCTAssertFalse(OpportunityEngine.evaluate(busy, settings: settings, history: []).shouldNotify)
        var moving = context
        moving.stepsRecent = 200
        XCTAssertFalse(OpportunityEngine.evaluate(moving, settings: settings, history: []).shouldNotify)
    }

    func testDailyPriorityEndsAfterFirstReminderAndZeroCooldownStillRespectsOutstandingPrompt() {
        var prior = plannedPrompt(context, plan: .init(date: now.addingTimeInterval(-7200), freeMinutes: 60, reason: "test"))
        prior.status = .expired
        XCTAssertEqual(ReminderPlanning.inactivityTarget(settings: settings, context: context, history: [prior]), 30)
        XCTAssertFalse(OpportunityEngine.evaluate(context, settings: settings, history: [prior]).shouldNotify)
        var noCooldown = settings
        noCooldown.cooldownMinutes = 0
        var sedentary = context
        sedentary.stationaryMinutes = 60
        prior.plannedFor = now.addingTimeInterval(-60)
        prior.status = .dismissed
        XCTAssertTrue(OpportunityEngine.evaluate(sedentary, settings: noCooldown, history: [prior]).shouldNotify)
        // Use a newly constructed live invitation to check the outstanding-prompt gate.
        let live = plannedPrompt(context, plan: .init(date: now, freeMinutes: 60, reason: "test"))
        XCTAssertFalse(OpportunityEngine.evaluate(sedentary, settings: noCooldown, history: [live]).shouldNotify)
    }

    func testLegacyFutureRequestsDoNotCountAsExposuresYet() throws {
        let plan = PlannedReminder(date: now.addingTimeInterval(120), freeMinutes: 60, reason: "legacy_plan")
        let prompt = plannedPrompt(context, plan: plan)
        XCTAssertEqual(plan.date, now.addingTimeInterval(120))
        XCTAssertFalse(prompt.isAvailable(at: now))
        XCTAssertTrue(prompt.isAvailable(at: plan.date))
        XCTAssertTrue(ReminderPlanning.dueHistory([prompt], at: now).isEmpty)
        XCTAssertEqual(ReminderPlanning.dueHistory([prompt], at: plan.date).count, 1)
        var cancelled = prompt
        cancelled.status = .cancelled
        cancelled.cancelledAt = now
        XCTAssertNil(cancelled.notificationDate)
        XCTAssertTrue(ReminderPlanning.dueHistory([cancelled], at: plan.date).isEmpty)
        cancelled.cancelledAt = plan.date.addingTimeInterval(30)
        XCTAssertEqual(ReminderPlanning.dueHistory([cancelled], at: plan.date.addingTimeInterval(60)).count, 1)
    }

    func testScheduledPromptPersistenceExpiryAndResponseUsePlannedTime() throws {
        let plan = PlannedReminder(date: now.addingTimeInterval(120), freeMinutes: 60, reason: "legacy_plan")
        let prompt = plannedPrompt(context, plan: plan)
        XCTAssertGreaterThan(prompt.expiresAt, plan.date)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try StudyStore(url: directory.appendingPathComponent("study.json"))
        try store.transaction { $0.prompts.append(prompt) }
        let restored = try StudyStore(url: store.url)
        XCTAssertEqual(restored.state.prompts[0].plannedFor, plan.date)
        XCTAssertThrowsError(try restored.respond(promptID: prompt.id, exerciseID: prompt.options[0].id, source: "app", at: now))
        try restored.expire(at: now)
        XCTAssertEqual(restored.state.prompts[0].status, .scheduled)
        XCTAssertTrue(try restored.respond(promptID: prompt.id, exerciseID: prompt.options[0].id, source: "notification", at: plan.date.addingTimeInterval(30)))
        let files = try restored.export(to: directory.appendingPathComponent("export"))
        let csv = try String(contentsOf: files[1], encoding: .utf8)
        XCTAssertTrue(csv.contains("planned_for,delivery_reason,notification_requested_at"))
        XCTAssertTrue(csv.contains("\"30.0\""))
    }

    func testWidgetTimelineAdvertisesPlanThenInvitationWithoutInventingNewCheck() {
        let fire = now.addingTimeInterval(120)
        let snapshot = ComplicationSnapshot(generatedAt: now, monitoring: true, checkedAt: now,
            invitationExpiresAt: fire.addingTimeInterval(600), invitationStartsAt: fire)
        XCTAssertEqual(snapshot.title(at: now), "Break planned")
        XCTAssertFalse(snapshot.invitationAvailable(at: now))
        XCTAssertTrue(snapshot.invitationAvailable(at: fire))
        XCTAssertEqual(snapshot.title(at: fire), "Choose a break")
        XCTAssertTrue(snapshot.transitionDates(after: now).contains(fire))
        XCTAssertEqual(snapshot.checkedAt, now)
    }
}
