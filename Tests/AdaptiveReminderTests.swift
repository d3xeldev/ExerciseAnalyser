import XCTest
@testable import ExerciseAnalyserCore

final class AdaptiveReminderTests: XCTestCase {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return calendar
    }

    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    var settings: Settings {
        var settings = Settings()
        settings.monitoring = true
        settings.dailyLimit = Settings.unlimitedDailyLimit
        return settings
    }

    func context(at date: Date) -> ContextSnapshot {
        var context = ContextSnapshot(date: date, timeZoneIdentifier: calendar.timeZone.identifier, localHour: calendar.component(.hour, from: date))
        context.calendarAvailable = true
        context.busyIntervals = []
        context.freeMinutes = 60
        context.heartRate = .init(value: 65, date: date)
        context.motion = .stationary
        context.motionObservedAt = date
        context.stationaryMinutes = 60
        return context
    }

    func prompt(at date: Date, status: PromptStatus = .selected) -> ExercisePrompt {
        var rng = StudyRandom(seed: 1)
        var prompt = RecommendationEngine.makePrompt(context: context(at: date),
            decision: .init(shouldNotify: true, score: 80, reasons: [], availableMinutes: 30),
            settings: settings, history: [], rng: &rng)!
        prompt.status = status
        prompt.scheduledAt = date
        if status == .selected {
            prompt.selectedExerciseID = prompt.options[0].id
            prompt.respondedAt = date.addingTimeInterval(30)
            prompt.completedAt = date.addingTimeInterval(300)
        }
        return prompt
    }

    func testLearnsWeekdayHourAndWaitsUntilItBeforeFirstReminder() throws {
        let history = [prompt(at: date(7, 15, 12)), prompt(at: date(14, 15, 45)), prompt(at: date(20, 11))]
        let early = context(at: date(21, 14, 50))
        let preference = try XCTUnwrap(ReminderPlanning.preferredTime(context: early, settings: settings, history: history))
        XCTAssertEqual(preference.date, date(21, 15))
        XCTAssertEqual(preference.reason, "learned_weekday_hour")
        XCTAssertFalse(OpportunityEngine.evaluate(early, settings: settings, history: history).shouldNotify)
        XCTAssertTrue(OpportunityEngine.evaluate(context(at: date(21, 15)), settings: settings, history: history).shouldNotify)
        let wake = try XCTUnwrap(BackgroundRefreshPolicy.plan(at: early.date, settings: settings, context: early, prompts: history, calendar: calendar))
        XCTAssertEqual(wake.date, preference.date)
        XCTAssertEqual(wake.reason, "preferred_reminder_time")
    }

    func testUnknownWeekdayUsesYesterdayAcceptedTimeIncludingMinutes() throws {
        let history = [prompt(at: date(20, 16, 25)), prompt(at: date(20, 18), status: .dismissed)]
        let preference = try XCTUnwrap(ReminderPlanning.preferredTime(context: context(at: date(21, 10)), settings: settings, history: history))
        XCTAssertEqual(preference.date, date(21, 16, 25))
        XCTAssertEqual(preference.reason, "previous_day_accepted_time")
        XCTAssertNil(ReminderPlanning.preferredTime(context: context(at: date(22, 10)), settings: settings, history: history))
    }

    func testKnownWeekdayDoesNotBorrowYesterdayOrLearnFromOneWeek() {
        let history = [prompt(at: date(14, 15)), prompt(at: date(20, 17))]
        XCTAssertNil(ReminderPlanning.preferredTime(context: context(at: date(21, 10)), settings: settings, history: history))
        let misses = [prompt(at: date(7, 15), status: .expired), prompt(at: date(14, 15), status: .dismissed)]
        XCTAssertNil(ReminderPlanning.preferredTime(context: context(at: date(21, 10)), settings: settings, history: misses))
    }

    func testLearningUsesDeliveryTimeAndHistoricalLocalTimeZone() throws {
        var first = prompt(at: date(7, 10))
        first.plannedFor = date(7, 15)
        var second = prompt(at: date(14, 10))
        second.plannedFor = date(14, 15)
        var current = context(at: date(21, 10))
        current.timeZoneIdentifier = "America/New_York"
        let preference = try XCTUnwrap(ReminderPlanning.preferredTime(context: current, settings: settings, history: [first, second]))
        XCTAssertEqual(ReminderPlanning.calendar(for: current).component(.hour, from: preference.date), 15)
    }

    func testPreferenceNeverOverridesBusyMovementOrQuietHours() {
        let history = [prompt(at: date(7, 15)), prompt(at: date(14, 15))]
        var current = context(at: date(21, 15))
        current.busyIntervals = [.init(start: date(21, 14), end: date(21, 16))]
        XCTAssertFalse(OpportunityEngine.evaluate(current, settings: settings, history: history).shouldNotify)
        current.busyIntervals = []
        current.stepsRecent = 100
        XCTAssertFalse(OpportunityEngine.evaluate(current, settings: settings, history: history).shouldNotify)
        var shortDay = settings
        shortDay.endHour = 14
        XCTAssertNil(ReminderPlanning.preferredTime(context: current, settings: shortDay, history: history))
    }

    func testBackoffStartsAtSecondMissAndKeepsGrowingByOnePointFive() throws {
        let now = date(21, 19)
        var history: [ExercisePrompt] = []
        for index in 0..<5 {
            let sent = date(21, 9 + index)
            history.append(prompt(at: sent, status: index % 2 == 0 ? .dismissed : .expired))
            let end = try XCTUnwrap(ReminderPlanning.cooldownEnd(settings: settings, history: history, at: now, calendar: calendar))
            XCTAssertEqual(end.timeIntervalSince(sent), 3600 * pow(1.5, Double(max(0, index))), accuracy: 0.01)
        }
    }

    func testAcceptanceBreaksMissStreakAndZeroCooldownStaysZero() throws {
        var history = [prompt(at: date(21, 9), status: .expired), prompt(at: date(21, 10), status: .dismissed), prompt(at: date(21, 12))]
        history.append(prompt(at: date(21, 14), status: .expired))
        XCTAssertEqual(ReminderPlanning.cooldownEnd(settings: settings, history: history, at: date(21, 15), calendar: calendar), date(21, 15))
        var zero = settings
        zero.cooldownMinutes = 0
        XCTAssertEqual(ReminderPlanning.cooldownEnd(settings: zero, history: history, at: date(21, 15), calendar: calendar), date(21, 14))
    }

    func testLocalMidnightResetsBackoffButPreservesBaseCooldown() {
        let history = [prompt(at: date(21, 19), status: .expired), prompt(at: date(21, 21), status: .dismissed), prompt(at: date(21, 23, 30), status: .expired)]
        XCTAssertEqual(ReminderPlanning.cooldownEnd(settings: settings, history: history, at: date(21, 23, 45), calendar: calendar), date(22, 0, 30))
        XCTAssertEqual(ReminderPlanning.cooldownEnd(settings: settings, history: history, at: date(22, 0, 10), calendar: calendar), date(22, 0, 30))
        let earlier = Array(history.prefix(2))
        XCTAssertEqual(ReminderPlanning.cooldownEnd(settings: settings, history: earlier, at: date(22, 0, 10), calendar: calendar), date(21, 22))
    }

    func testExpiredUnprocessedRequestCountsButCancelledFutureRequestDoesNot() {
        let first = prompt(at: date(21, 10), status: .dismissed)
        let ignored = prompt(at: date(21, 11), status: .scheduled)
        var cancelled = prompt(at: date(21, 11, 30), status: .cancelled)
        cancelled.plannedFor = date(21, 12)
        cancelled.cancelledAt = date(21, 11, 45)
        XCTAssertEqual(ReminderPlanning.cooldownEnd(settings: settings, history: [first, ignored, cancelled], at: date(21, 12), calendar: calendar), date(21, 12, 30))
        XCTAssertFalse(OpportunityEngine.evaluate(context(at: date(21, 12)), settings: settings, history: [first, ignored]).shouldNotify)
    }

    func testPostEventRequiresTwoMinutesAndMovementEvidenceAcrossWholeEvent() {
        let event = DateInterval(start: date(21, 13), end: date(21, 14))
        var current = context(at: date(21, 14, 1))
        current.busyIntervals = [event]
        current.lastBusyEventActivity = .init(interval: event, steps: 40)
        current.stationaryMinutes = 2
        XCTAssertFalse(OpportunityEngine.evaluate(current, settings: settings, history: []).shouldNotify)
        current.date = date(21, 14, 2)
        XCTAssertTrue(OpportunityEngine.evaluate(current, settings: settings, history: []).shouldNotify)
        current.lastBusyEventActivity = .init(interval: event, steps: 100)
        XCTAssertFalse(OpportunityEngine.evaluate(current, settings: settings, history: []).shouldNotify)
        current.lastBusyEventActivity = nil
        XCTAssertFalse(OpportunityEngine.evaluate(current, settings: settings, history: []).shouldNotify)
    }

    func testPostEventChecksApplyAfterFirstDailyReminderAndRespectCooldown() {
        let event = DateInterval(start: date(21, 13), end: date(21, 14))
        var current = context(at: date(21, 14, 2))
        current.busyIntervals = [event]
        current.lastBusyEventActivity = .init(interval: event, steps: 0)
        current.stationaryMinutes = 2
        XCTAssertTrue(OpportunityEngine.evaluate(current, settings: settings, history: [prompt(at: date(21, 10))]).shouldNotify)
        XCTAssertFalse(OpportunityEngine.evaluate(current, settings: settings, history: [prompt(at: date(21, 13, 30))]).shouldNotify)
        current.heartRate = nil
        XCTAssertFalse(OpportunityEngine.evaluate(current, settings: settings, history: []).shouldNotify)
    }

    func testOverlappingEventsMergeAndChangedEventInvalidatesMovementEvidence() throws {
        var current = context(at: date(21, 14, 2))
        current.busyIntervals = [.init(start: date(21, 12), end: date(21, 13, 30)), .init(start: date(21, 13), end: date(21, 14))]
        let event = try XCTUnwrap(ReminderPlanning.recentBusyEvent(context: current))
        XCTAssertEqual(event, DateInterval(start: date(21, 12), end: date(21, 14)))
        current.lastBusyEventActivity = .init(interval: event, steps: 20)
        XCTAssertTrue(OpportunityEngine.evaluate(current, settings: settings, history: []).shouldNotify)
        current.busyIntervals?.append(.init(start: date(21, 11), end: date(21, 12, 30)))
        XCTAssertFalse(OpportunityEngine.evaluate(current, settings: settings, history: []).shouldNotify)
        current.busyIntervals?.append(.init(start: date(21, 14, 1), end: date(21, 15)))
        XCTAssertFalse(OpportunityEngine.evaluate(current, settings: settings, history: []).shouldNotify)
    }

    func testWholeEventStepEvidenceIncludesBoundarySamplesAndNeverInventsZero() {
        let event = DateInterval(start: date(21, 13), end: date(21, 14))
        XCTAssertNil(StepEvidence.stepsDuringEvent(event, samples: []))
        XCTAssertNil(StepEvidence.stepsDuringEvent(event, samples: [(.init(start: date(21, 14, 1), end: date(21, 14, 2)), 10)]))
        XCTAssertEqual(StepEvidence.stepsDuringEvent(event, samples: [(.init(start: date(21, 12), end: date(21, 12, 5)), 100)]), 0)
        let samples: [(interval: DateInterval, steps: Double)] = [
            (.init(start: date(21, 12, 59), end: date(21, 13, 2)), 40),
            (.init(start: date(21, 13, 59), end: date(21, 14, 1)), 60),
            (.init(start: date(21, 14, 2), end: date(21, 14, 3)), 200)
        ]
        XCTAssertEqual(StepEvidence.stepsDuringEvent(event, samples: samples), 100)
    }

    func testExtraBackoffStopsAtLocalMidnightAndDoesNotPenalizeTomorrow() {
        let history = (0..<5).map { prompt(at: date(21, 18 + $0), status: .expired) }
        XCTAssertEqual(ReminderPlanning.cooldownEnd(settings: settings, history: history, at: date(21, 23), calendar: calendar), date(22, 0))
        XCTAssertEqual(ReminderPlanning.cooldownEnd(settings: settings, history: history, at: date(22, 0), calendar: calendar), date(21, 23))
        let nextDay = history + [prompt(at: date(22, 10), status: .dismissed)]
        XCTAssertEqual(ReminderPlanning.cooldownEnd(settings: settings, history: nextDay, at: date(22, 11), calendar: calendar), date(22, 11))
    }

    func testWakeAtTwoMinutesAfterAnEventEvenDuringTheGracePeriod() throws {
        var current = context(at: date(21, 14, 1))
        current.busyIntervals = [.init(start: date(21, 13), end: date(21, 14))]
        let plan = try XCTUnwrap(BackgroundRefreshPolicy.plan(at: current.date, settings: settings, context: current, prompts: [], calendar: calendar))
        XCTAssertEqual(plan.date, date(21, 14, 2))
        XCTAssertEqual(plan.reason, "busy_event_ends")
    }
}
