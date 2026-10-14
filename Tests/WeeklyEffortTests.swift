import XCTest
@testable import ExerciseAnalyserCore

final class WeeklyEffortTests: XCTestCase {
    func testRollingWeekExcludesExpiredAndFutureCompletions() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let boundary = calendar.date(byAdding: .day, value: -7, to: now)!
        let snapshot = ComplicationSnapshot(generatedAt: now, monitoring: true, effortCompletions: [
            .init(date: boundary, effort: "easy"),
            .init(date: boundary.addingTimeInterval(1), effort: "easy"),
            .init(date: now, effort: "moderate"),
            .init(date: now.addingTimeInterval(1), effort: "challenge")
        ])
        XCTAssertEqual(snapshot.weeklyEffortCounts(at: now, calendar: calendar), [1, 1, 0])
        XCTAssertTrue(snapshot.transitionDates(after: now, calendar: calendar).contains(now.addingTimeInterval(1)))
        XCTAssertEqual(snapshot.weeklyEffortCounts(at: now.addingTimeInterval(1), calendar: calendar), [0, 1, 1])
    }

    func testDailyBarsUseCalendarDaysAndExcludeFutureCompletions() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 12))!
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -6, to: today)!
        let snapshot = ComplicationSnapshot(generatedAt: now, monitoring: true, effortCompletions: [
            .init(date: firstDay.addingTimeInterval(-1), effort: "easy"),
            .init(date: firstDay, effort: "moderate"),
            .init(date: today.addingTimeInterval(-1), effort: "challenge"),
            .init(date: today, effort: "easy"),
            .init(date: now.addingTimeInterval(1), effort: "moderate")
        ])
        let days = snapshot.dailyEffortCounts(at: now, calendar: calendar)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.first?.date, firstDay)
        XCTAssertEqual(days[0].counts, [0, 1, 0])
        XCTAssertEqual(days[1].counts, [0, 0, 0])
        XCTAssertEqual(days[5].counts, [0, 0, 1])
        XCTAssertEqual(days[6].counts, [1, 0, 0])
        XCTAssertEqual(ComplicationSnapshot.empty(at: now).dailyEffortCounts(at: now, calendar: calendar).map(\.counts), Array(repeating: [0, 0, 0], count: 7))
    }

    func testOldCacheWithoutEffortDataStillDecodes() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let original = ComplicationSnapshot(generatedAt: now, monitoring: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ComplicationSnapshot.self, from: data)
        XCTAssertNil(decoded.effortCompletions)
        XCTAssertEqual(decoded.weeklyEffortCounts(at: now), [0, 0, 0])
    }
}
