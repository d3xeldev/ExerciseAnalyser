import XCTest
@testable import ExerciseAnalyserCore

final class CalendarSelectionTests: XCTestCase {
    func testLegacySettingsCheckAllCalendarsIncludingNewOnes() throws {
        let encoded = try JSONEncoder().encode(Settings())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        json.removeValue(forKey: "selectedCalendarIDs")
        let restored = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.selectedCalendarIDs)
        XCTAssertTrue(restored.checksCalendar("existing"))
        XCTAssertTrue(restored.checksCalendar("new"))
    }

    func testSelectionSurvivesReloadAndExcludesOtherCalendars() throws {
        var settings = Settings()
        settings.selectedCalendarIDs = ["work", "personal"]
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored, settings)
        XCTAssertTrue(restored.checksCalendar("work"))
        XCTAssertTrue(restored.checksCalendar("personal"))
        XCTAssertFalse(restored.checksCalendar("holidays"))
        XCTAssertFalse(restored.checksCalendar("new"))
    }

    func testEmptySelectionRemainsDistinctFromAllCalendarsAfterReload() throws {
        var settings = Settings()
        settings.selectedCalendarIDs = []
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(restored.selectedCalendarIDs, [])
        XCTAssertFalse(restored.checksCalendar("work"))
    }
}
