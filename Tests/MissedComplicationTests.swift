import XCTest
@testable import ExerciseAnalyserCore

final class MissedComplicationTests: XCTestCase {
    func testMissedCountsRollOverWithoutShowingYesterdaysCountAsToday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12)))
        let today = calendar.startOfDay(for: now)
        let yesterday = try XCTUnwrap(calendar.date(byAdding: .day, value: -1, to: today))
        let tomorrow = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: today))
        var snapshot = ComplicationSnapshot(generatedAt: now, monitoring: true)
        snapshot.missedHistory = [.init(date: yesterday, value: 0), .init(date: today, value: 3)]
        let days = snapshot.weeklyMissedDays(at: now, calendar: calendar)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days[5].value, 0)
        XCTAssertEqual(days[6].value, 3)
        XCTAssertNil(days[0].value)
        XCTAssertEqual(snapshot.missedToday(at: now, calendar: calendar), 3)
        XCTAssertNil(snapshot.missedToday(at: tomorrow, calendar: calendar))
        XCTAssertEqual(snapshot.weeklyMissedDays(at: tomorrow, calendar: calendar)[5].value, 3)
        XCTAssertNil(snapshot.weeklyMissedDays(at: tomorrow, calendar: calendar)[6].value)
        XCTAssertNil(snapshot.missedToday(at: now.addingTimeInterval(-1), calendar: calendar))
        snapshot.dataAvailable = false
        XCTAssertNil(snapshot.missedToday(at: now, calendar: calendar))
        XCTAssertTrue(snapshot.weeklyMissedDays(at: now, calendar: calendar).allSatisfy { $0.value == nil })
    }

    func testLegacyCacheDoesNotInventZeroMisses() throws {
        let now = Date()
        let legacy = ComplicationSnapshot(generatedAt: now, monitoring: true)
        let restored = try JSONDecoder().decode(ComplicationSnapshot.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(restored.missedHistory)
        XCTAssertNil(restored.missedToday(at: now))
        XCTAssertEqual(ComplicationKind.missed.url.absoluteString, "movemoment://missed")
    }
}
