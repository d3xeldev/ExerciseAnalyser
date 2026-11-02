import XCTest
@testable import ExerciseAnalyserCore

final class CompanionSummaryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return calendar
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12))!
    }

    private func prompt(at date: Date, status: PromptStatus) -> ExercisePrompt {
        var rng = StudyRandom(seed: 1)
        let context = ContextSnapshot(date: date, timeZoneIdentifier: calendar.timeZone.identifier,
                                      localHour: calendar.component(.hour, from: date))
        var prompt = RecommendationEngine.makePrompt(context: context,
            decision: .init(shouldNotify: true, score: 80, reasons: [], availableMinutes: 30),
            settings: Settings(), history: [], rng: &rng)!
        prompt.status = status
        prompt.scheduledAt = date
        return prompt
    }

    func testOnlyResolvedMissesCount() {
        let statuses: [PromptStatus] = [.prepared, .scheduled, .selected, .dismissed, .expired, .ignored, .cancelled, .failed]
        var history = statuses.map { prompt(at: now.addingTimeInterval(-600), status: $0) }
        var completed = prompt(at: now, status: .selected)
        completed.completedAt = now
        var abandoned = prompt(at: now, status: .dismissed)
        abandoned.abandonedAt = now
        history += [completed, abandoned]
        XCTAssertEqual(CompanionSummary.missedCount(in: history, on: now, asOf: now, calendar: calendar), 3)
    }

    func testMissesUseFullHistoryRatherThanLatestThirtyPrompts() {
        let history = (0..<45).map { _ in prompt(at: now, status: .expired) }
        XCTAssertEqual(CompanionSummary.missedCount(in: history, on: now, asOf: now, calendar: calendar), 45)
    }

    func testInvitationDayUsesCalendarBoundariesAndPlannedTime() {
        let midnight = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: midnight)!
        var plannedToday = prompt(at: midnight.addingTimeInterval(-3600), status: .expired)
        plannedToday.plannedFor = midnight.addingTimeInterval(3600)
        let history = [
            prompt(at: midnight.addingTimeInterval(-1), status: .expired),
            prompt(at: midnight, status: .ignored),
            prompt(at: now.addingTimeInterval(1), status: .dismissed),
            prompt(at: tomorrow, status: .expired),
            plannedToday
        ]
        XCTAssertEqual(CompanionSummary.missedCount(in: history, on: now, asOf: now, calendar: calendar), 2)
        XCTAssertEqual(CompanionSummary.missedCount(in: history, on: midnight.addingTimeInterval(-1), asOf: now, calendar: calendar), 1)
    }

    func testManualMissesUseCreationDayWithoutNotification() {
        var manual = prompt(at: now, status: .ignored)
        manual.deliveryReason = "manual_intervention"
        manual.scheduledAt = nil
        XCTAssertEqual(CompanionSummary.missedCount(in: [manual], on: now, asOf: now, calendar: calendar), 1)
    }

    func testOlderSummaryKeepsMissedUnavailableAndNewCountRoundTrips() throws {
        let legacy = Data("{\"date\":0,\"low\":1,\"moderate\":2,\"high\":0}".utf8)
        let oldDay = try JSONDecoder().decode(CompanionSnapshot.Day.self, from: legacy)
        XCTAssertNil(oldDay.missed)
        XCTAssertNil(oldDay.selections)
        XCTAssertNil(oldDay.exerciseMinutes)
        XCTAssertEqual(oldDay.completed, 3)
        for count in [0, 5] {
            let day = CompanionSnapshot.Day(date: now, steps: nil, low: 1, moderate: 2, high: 0, missed: count)
            let copy = try JSONDecoder().decode(CompanionSnapshot.Day.self, from: JSONEncoder().encode(day))
            XCTAssertEqual(copy.missed, count)
            XCTAssertEqual(copy.completed, 3)
        }
    }

    func testExerciseMinutesPreserveMissingZeroAndRecordedValues() throws {
        for minutes: Double? in [nil, 0, 24.5] {
            let day = CompanionSnapshot.Day(date: now, steps: 1200, low: 1, moderate: 0, high: 0,
                                            exerciseMinutes: minutes)
            let copy = try JSONDecoder().decode(CompanionSnapshot.Day.self, from: JSONEncoder().encode(day))
            XCTAssertEqual(copy.exerciseMinutes, minutes)
            XCTAssertEqual(copy.steps, 1200)
            XCTAssertEqual(copy.completed, 1)
        }
    }

    func testSelectionsUseChoiceDayAndIncludeUnfinishedBreaks() throws {
        let midnight = calendar.startOfDay(for: now)
        var low = prompt(at: midnight.addingTimeInterval(-600), status: .ignored)
        low.selectedExerciseID = try XCTUnwrap(low.options.first { $0.exercise.effort == .easy }).id
        low.respondedAt = midnight
        var high = prompt(at: now, status: .selected)
        high.selectedExerciseID = try XCTUnwrap(high.options.first { $0.exercise.effort == .challenge }).id
        high.respondedAt = now
        var yesterday = low
        yesterday.respondedAt = midnight.addingTimeInterval(-1)
        var future = high
        future.respondedAt = now.addingTimeInterval(1)
        let unselected = prompt(at: now, status: .scheduled)
        let counts = CompanionSummary.selectionCounts(in: [low, high, yesterday, future, unselected], on: now, asOf: now, calendar: calendar)
        XCTAssertEqual(counts.low, 1)
        XCTAssertEqual(counts.moderate, 0)
        XCTAssertEqual(counts.high, 1)
        XCTAssertEqual(counts.dominant, "easy")
    }

    func testSelectionCountsUseFullHistory() throws {
        var selected = prompt(at: now, status: .selected)
        selected.selectedExerciseID = try XCTUnwrap(selected.options.first { $0.exercise.effort == .moderate }).id
        selected.respondedAt = now
        let counts = CompanionSummary.selectionCounts(in: Array(repeating: selected, count: 45), on: now, asOf: now, calendar: calendar)
        XCTAssertEqual(counts.moderate, 45)
        XCTAssertEqual(counts.dominant, "moderate")
    }

    func testDominantEffortAndSelectionSummaryRoundTrip() throws {
        XCTAssertNil(CompanionSnapshot.EffortCounts(low: 0, moderate: 0, high: 0).dominant)
        XCTAssertEqual(CompanionSnapshot.EffortCounts(low: 1, moderate: 2, high: 3).dominant, "challenge")
        XCTAssertEqual(CompanionSnapshot.EffortCounts(low: 1, moderate: 2, high: 2).dominant, "moderate")
        let day = CompanionSnapshot.Day(date: now, steps: nil, low: 0, moderate: 0, high: 0,
                                        selections: .init(low: 0, moderate: 0, high: 1))
        let copy = try JSONDecoder().decode(CompanionSnapshot.Day.self, from: JSONEncoder().encode(day))
        XCTAssertEqual(copy.completed, 0)
        XCTAssertEqual(copy.selections?.dominant, "challenge")
    }
}
