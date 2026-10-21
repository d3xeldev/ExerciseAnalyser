import XCTest
@testable import ExerciseAnalyserCore

final class BackgroundHealthCacheTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 14))!
    }

    private func entry(at date: Date) -> CachedHealthValue<Double> {
        .init(value: 7.5, collectedAt: date, timeZoneIdentifier: calendar.timeZone.identifier,
              provenance: .init(source: "HealthKit", unit: "h", windowStart: date.addingTimeInterval(-86400),
                                windowEnd: date, sampleDate: nil, availability: "available"))
    }

    func testThreeQuarterHourlyChecksReusePersistedValueThenExpire() throws {
        let original = BackgroundHealthCache(sleepHours: entry(at: now))
        let restored = try JSONDecoder().decode(BackgroundHealthCache.self, from: JSONEncoder().encode(original))
        for minutes in [15, 30, 45] {
            let hit = try XCTUnwrap(restored.available(at: now.addingTimeInterval(Double(minutes * 60)), calendar: calendar).sleepHours)
            XCTAssertEqual(hit.value, 7.5)
            XCTAssertEqual(hit.collectedAt, now)
            XCTAssertEqual(hit.cachedProvenance.source, "HealthKit_cache")
            XCTAssertEqual(hit.cachedProvenance.windowEnd, now)
            XCTAssertEqual(hit.cachedProvenance.windowStart, now.addingTimeInterval(-86400))
        }
        XCTAssertNil(restored.available(at: now.addingTimeInterval(3600), calendar: calendar).sleepHours)
        XCTAssertNil(restored.available(at: now.addingTimeInterval(-1), calendar: calendar).sleepHours)
    }

    func testDayAndTimeZoneChangesInvalidateValues() {
        let late = calendar.date(bySettingHour: 23, minute: 50, second: 0, of: now)!
        XCTAssertFalse(entry(at: late).usable(at: late.addingTimeInterval(900), calendar: calendar))
        var changedZone = calendar
        changedZone.timeZone = TimeZone(secondsFromGMT: 3600)!
        XCTAssertFalse(entry(at: now).usable(at: now.addingTimeInterval(900), calendar: changedZone))
    }

    func testEntriesExpireIndependentlyAndMissingValuesStayMissing() throws {
        let resting = CachedHealthValue(value: Measurement(value: 60, date: now), collectedAt: now,
            timeZoneIdentifier: calendar.timeZone.identifier,
            provenance: .init(source: "HealthKit", unit: "bpm", windowStart: now.addingTimeInterval(-604800),
                              windowEnd: now, sampleDate: now, availability: "available"))
        let cache = BackgroundHealthCache(restingHeartRate: resting, sleepHours: entry(at: now.addingTimeInterval(-3600)))
        let available = cache.available(at: now, calendar: calendar)
        XCTAssertNil(available.stepHistory)
        XCTAssertNil(available.sleepHours)
        XCTAssertEqual(try XCTUnwrap(available.restingHeartRate).value.date, now)
        XCTAssertEqual(available.restingHeartRate?.cachedProvenance.sampleDate, now)
    }

    func testNewDefaultDoesNotOverwriteSavedReminderLimit() throws {
        XCTAssertEqual(Settings().dailyLimit, 6)
        var saved = Settings()
        saved.dailyLimit = 3
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(saved))
        XCTAssertEqual(restored.dailyLimit, 3)
    }
}
