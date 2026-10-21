import XCTest
@testable import ExerciseAnalyserCore

final class ProactiveMonitoringTests: XCTestCase {
    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        return value
    }

    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 14))! }

    var settings: Settings {
        var value = Settings()
        value.monitoring = true
        return value
    }

    func testRegularCadenceAndPausedMonitoring() throws {
        let plan = try XCTUnwrap(BackgroundRefreshPolicy.plan(at: now, settings: settings, context: nil, prompts: [], calendar: calendar))
        XCTAssertEqual(plan.date.timeIntervalSince(now), 15 * 60)
        var paused = settings
        paused.monitoring = false
        XCTAssertNil(BackgroundRefreshPolicy.plan(at: now, settings: paused, context: nil, prompts: [], calendar: calendar))
    }

    func testEventEndingAndThresholdAreEarlierOpportunities() throws {
        var context = ContextSnapshot(date: now, localHour: 14)
        context.busyUntil = now.addingTimeInterval(120)
        let meeting = try XCTUnwrap(BackgroundRefreshPolicy.plan(at: now, settings: settings, context: context, prompts: [], calendar: calendar))
        XCTAssertEqual(meeting.date.timeIntervalSince(now), 240)
        XCTAssertEqual(meeting.reason, "busy_event_ends")
        context.busyUntil = nil
        context.motion = .stationary
        context.motionObservedAt = now
        context.heartRate = .init(value: 60, date: now)
        context.stationaryMinutes = Double(ReminderPlanning.inactivityTarget(settings: settings, context: context, history: [])) - 0.2
        let threshold = try XCTUnwrap(BackgroundRefreshPolicy.plan(at: now, settings: settings, context: context, prompts: [], calendar: calendar))
        XCTAssertEqual(threshold.date.timeIntervalSince(now), 60, "Near transitions should not create sub-minute retry loops")
        XCTAssertEqual(threshold.reason, "inactivity_threshold")
    }

    func testOldContextDoesNotPredictOpportunities() throws {
        var context = ContextSnapshot(date: now.addingTimeInterval(-3600), localHour: 13)
        context.busyUntil = now.addingTimeInterval(120)
        let plan = try XCTUnwrap(BackgroundRefreshPolicy.plan(at: now, settings: settings, context: context, prompts: [], calendar: calendar))
        XCTAssertEqual(plan.reason, "regular_15_minute_check")
    }

    func testQuietHoursAndOvernightWindow() throws {
        let late = calendar.date(bySettingHour: 23, minute: 0, second: 0, of: now)!
        let plan = try XCTUnwrap(BackgroundRefreshPolicy.plan(at: late, settings: settings, context: nil, prompts: [], calendar: calendar))
        XCTAssertEqual(calendar.component(.hour, from: plan.date), 9)
        XCTAssertEqual(calendar.component(.day, from: plan.date), 11)
        XCTAssertEqual(plan.reason, "active_hours_begin")
        var overnight = settings
        overnight.startHour = 22
        overnight.endHour = 6
        let night = try XCTUnwrap(BackgroundRefreshPolicy.plan(at: late, settings: overnight, context: nil, prompts: [], calendar: calendar))
        XCTAssertEqual(night.date.timeIntervalSince(late), 900)
        overnight.startHour = overnight.endHour
        XCTAssertNil(BackgroundRefreshPolicy.plan(at: late, settings: overnight, context: nil, prompts: [], calendar: calendar))
    }

    func testMinutePrecisionForActiveHoursAndRefresh() throws {
        var preferences = settings
        preferences.startHour = 14
        preferences.startMinute = 30
        preferences.endHour = 14
        preferences.endMinute = 45
        XCTAssertFalse(preferences.isActive(hour: 14, minute: 29))
        XCTAssertTrue(preferences.isActive(hour: 14, minute: 30))
        XCTAssertTrue(preferences.isActive(hour: 14, minute: 44))
        XCTAssertFalse(preferences.isActive(hour: 14, minute: 45))
        let plan = try XCTUnwrap(BackgroundRefreshPolicy.plan(at: now, settings: preferences, context: nil, prompts: [], calendar: calendar))
        XCTAssertEqual(plan.date, now.addingTimeInterval(30 * 60))
        var context = ContextSnapshot(date: now.addingTimeInterval(40 * 60), timeZoneIdentifier: "UTC", localHour: 14)
        context.calendarAvailable = true
        context.busyIntervals = []
        XCTAssertEqual(ReminderPlanning.freeMinutes(at: context.date, context: context, settings: preferences), 5)
        XCTAssertFalse(OpportunityEngine.evaluate(context, settings: preferences, history: []).reasons.contains("Quiet hours"))
        context.date = now.addingTimeInterval(45 * 60)
        XCTAssertTrue(OpportunityEngine.evaluate(context, settings: preferences, history: []).reasons.contains("Quiet hours"))
        preferences.startHour = 22
        preferences.endHour = 6
        XCTAssertTrue(preferences.isActive(hour: 23, minute: 0))
        XCTAssertTrue(preferences.isActive(hour: 6, minute: 44))
        XCTAssertFalse(preferences.isActive(hour: 6, minute: 45))
        XCTAssertFalse(preferences.isActive(hour: 22, minute: 29))
    }

    func testTimePreferencesRoundTripAndLegacyDefaults() throws {
        var preferences = settings
        preferences.startMinute = 25
        preferences.endMinute = 50
        let encoded = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: encoded), preferences)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "startMinute")
        legacy.removeValue(forKey: "endMinute")
        let restored = try JSONDecoder().decode(Settings.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertEqual(restored.startMinuteOfDay, preferences.startHour * 60)
        XCTAssertEqual(restored.endMinuteOfDay, preferences.endHour * 60)
    }

    func testRecentOutstandingWakeIsNotPushedLaterAndSurvivesSerialization() throws {
        let pending = RefreshRequest(requestedAt: now, preferredDate: now.addingTimeInterval(120), reason: "busy_event_ends")
        let restored = try JSONDecoder().decode(RefreshRequest.self, from: JSONEncoder().encode(pending))
        XCTAssertEqual(restored, pending)
        XCTAssertFalse(BackgroundRefreshPolicy.shouldReplace(restored, with: .init(date: now.addingTimeInterval(900), reason: "regular"), at: now))
        XCTAssertTrue(BackgroundRefreshPolicy.shouldReplace(restored, with: .init(date: now.addingTimeInterval(60), reason: "earlier"), at: now))
        let overdue = RefreshRequest(requestedAt: now.addingTimeInterval(-900), preferredDate: now.addingTimeInterval(-120), reason: "delayed")
        XCTAssertFalse(BackgroundRefreshPolicy.shouldReplace(overdue, with: .init(date: now.addingTimeInterval(900), reason: "regular"), at: now))
    }

    func testStuckRequestCanRecoverAfterGracePeriod() {
        let stale = RefreshRequest(requestedAt: now.addingTimeInterval(-7200), preferredDate: now.addingTimeInterval(-1800), reason: "old")
        let plan = RefreshPlan(date: now.addingTimeInterval(900), reason: "regular")
        XCTAssertTrue(BackgroundRefreshPolicy.shouldReplace(stale, with: plan, at: now))
        XCTAssertFalse(BackgroundRefreshPolicy.shouldReplace(stale, with: plan, at: now.addingTimeInterval(-1)))
        let repaired = BackgroundRefreshPolicy.recoveredRequest(stale, plan: plan, at: now)
        XCTAssertGreaterThan(repaired.preferredDate, now)
        XCTAssertNotEqual(repaired.id, stale.id)
        XCTAssertEqual(repaired.reason, "recover_overdue_regular")
        XCTAssertFalse(BackgroundRefreshPolicy.shouldReplace(repaired, with: plan, at: now.addingTimeInterval(30)))
    }

    func testRelaunchRearmsFutureRequestButNeverResubmitsPastDate() {
        let plan = RefreshPlan(date: now.addingTimeInterval(900), reason: "regular")
        let future = RefreshRequest(requestedAt: now, preferredDate: now.addingTimeInterval(120), reason: "meeting")
        XCTAssertEqual(BackgroundRefreshPolicy.recoveredRequest(future, plan: plan, at: now), future)
        let due = RefreshRequest(requestedAt: now.addingTimeInterval(-900), preferredDate: now, reason: "regular")
        XCTAssertEqual(BackgroundRefreshPolicy.recoveredRequest(due, plan: plan, at: now).preferredDate, plan.date)
    }

    func testCallbacksWithoutMetadataConsumeDueRequestButNotNewerFutureRequest() {
        let due = RefreshRequest(requestedAt: now.addingTimeInterval(-900), preferredDate: now, reason: "regular")
        XCTAssertTrue(BackgroundRefreshPolicy.consumes(due, callbackID: nil, at: now))
        XCTAssertTrue(BackgroundRefreshPolicy.consumes(due, callbackID: due.id.uuidString, at: now))
        XCTAssertFalse(BackgroundRefreshPolicy.consumes(due, callbackID: UUID().uuidString, at: now))
        let future = RefreshRequest(requestedAt: now, preferredDate: now.addingTimeInterval(900), reason: "regular")
        XCTAssertFalse(BackgroundRefreshPolicy.consumes(future, callbackID: nil, at: now))
        XCTAssertFalse(BackgroundRefreshPolicy.consumes(future, callbackID: due.id.uuidString, at: now))
        XCTAssertFalse(BackgroundRefreshPolicy.consumes(nil, callbackID: nil, at: now))
    }

    func testSnapshotFreshnessAndInvitationExpiry() {
        let snapshot = ComplicationSnapshot(generatedAt: now, monitoring: true, checkedAt: now, lowMovementMinutes: 45,
                                           invitationExpiresAt: now.addingTimeInterval(120))
        XCTAssertTrue(snapshot.invitationAvailable(at: now))
        XCTAssertEqual(snapshot.title(at: now), "Choose a break")
        XCTAssertFalse(snapshot.invitationAvailable(at: now.addingTimeInterval(120)))
        XCTAssertFalse(snapshot.isFresh(at: now.addingTimeInterval(1800)))
        XCTAssertEqual(snapshot.title(at: now.addingTimeInterval(1800)), "Awaiting an update")
        XCTAssertFalse(snapshot.isFresh(at: now.addingTimeInterval(-1)))
        XCTAssertEqual(snapshot.transitionDates(after: now, calendar: calendar).first, now.addingTimeInterval(120))
    }

    func testSuspendedCollectionCannotDriveDecisionAfterResume() {
        let context = ContextSnapshot(date: now, localHour: 14)
        XCTAssertTrue(context.isTimelyForDecision(at: now.addingTimeInterval(5)))
        XCTAssertFalse(context.isTimelyForDecision(at: now.addingTimeInterval(16)))
        XCTAssertFalse(context.isTimelyForDecision(at: now.addingTimeInterval(16 * 3600)))
        XCTAssertFalse(context.isTimelyForDecision(at: now.addingTimeInterval(-1)))
    }

    func testDailyValuesExpireAtMidnightEvenWhenSampleIsFresh() {
        let late = calendar.date(bySettingHour: 23, minute: 59, second: 0, of: now)!
        let nextDay = late.addingTimeInterval(120)
        let snapshot = ComplicationSnapshot(generatedAt: late, monitoring: true, checkedAt: late, steps: 7500, completedToday: 3)
        XCTAssertTrue(snapshot.hasCurrentActivity(at: late, calendar: calendar))
        XCTAssertEqual(snapshot.completions(at: late, calendar: calendar), 3)
        XCTAssertFalse(snapshot.hasCurrentActivity(at: nextDay, calendar: calendar))
        XCTAssertNil(snapshot.completions(at: nextDay, calendar: calendar))
        XCTAssertTrue(snapshot.transitionDates(after: late, calendar: calendar).contains(calendar.startOfDay(for: nextDay)))
    }

    func testPausedSnapshotCannotAdvertiseInvitation() {
        let snapshot = ComplicationSnapshot(generatedAt: now, monitoring: false, checkedAt: now, invitationExpiresAt: now.addingTimeInterval(300))
        XCTAssertFalse(snapshot.invitationAvailable(at: now))
        XCTAssertEqual(snapshot.title(at: now), "Paused")
        XCTAssertEqual(ComplicationSnapshot.empty(at: now).title(at: now), "Open to set up")
    }

    func testCacheRoundTripAndMalformedFallback() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")
        let snapshot = ComplicationSnapshot(generatedAt: now, monitoring: true, checkedAt: now, steps: 2500, completedToday: 2)
        try ComplicationCache.write(snapshot, to: url)
        XCTAssertEqual(ComplicationCache.read(from: url), snapshot)
        let data = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(data.contains("participantID"))
        XCTAssertFalse(data.contains("heartRate"))
        try Data("corrupt".utf8).write(to: url)
        XCTAssertNil(ComplicationCache.read(from: url))
        XCTAssertNil(ComplicationCache.read(from: nil))
        var unsupported = snapshot
        unsupported.schemaVersion = 2
        try ComplicationCache.write(unsupported, to: url)
        XCTAssertNil(ComplicationCache.read(from: url))
    }
}
