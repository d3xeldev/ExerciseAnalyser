import XCTest
@testable import ExerciseAnalyserCore

final class ExerciseAnalyserCoreTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_791_626_400)

    func context() -> ContextSnapshot {
        var value = ContextSnapshot(date: now, timeZoneIdentifier: "UTC", localHour: 14)
        value.calendarAvailable = true
        value.freeMinutes = 30
        value.heartRate = .init(value: 65, date: now.addingTimeInterval(-300))
        value.motion = .stationary
        value.stationaryMinutes = 60
        value.motionObservedAt = now
        return value
    }

    func settings() -> Settings {
        var value = Settings()
        value.monitoring = true
        return value
    }

    func prompt(settings custom: Settings? = nil, history: [ExercisePrompt] = [], seed: UInt64 = 1) -> ExercisePrompt {
        var rng = SeededRandom(seed: seed)
        return RecommendationEngine.makePrompt(context: context(), decision: .init(shouldNotify: true, score: 80, reasons: [], availableMinutes: 30),
                                               settings: custom ?? settings(), history: history, rng: &rng)!
    }

    func testUnfinishedSelectionStopsBlockingAfterFeedbackWindow() throws {
        var selected = prompt()
        selected.status = .selected
        selected.selectedExerciseID = selected.options[0].id
        selected.respondedAt = now.addingTimeInterval(-599)
        XCTAssertFalse(OpportunityEngine.evaluate(context(), settings: settings(), history: [selected]).shouldNotify)
        selected.respondedAt = now.addingTimeInterval(-600)
        let restored = try StudyStore.decoder.decode(ExercisePrompt.self, from: StudyStore.encoder.encode(selected))
        XCTAssertTrue(OpportunityEngine.evaluate(context(), settings: settings(), history: [restored]).shouldNotify)
        XCTAssertFalse(restored.isActive(at: now))
        XCTAssertEqual(restored.status, .selected)
        XCTAssertNil(restored.completedAt)
        XCTAssertNil(restored.abandonedAt)
    }

    func testRunningPausedAndEndedBreaksHaveBoundedFeedbackWindows() {
        var selected = prompt()
        selected.status = .selected
        selected.selectedExerciseID = selected.options[0].id
        selected.respondedAt = now
        let exercise = selected.options[0].exercise
        var session = ExerciseSession()
        session.start(at: now.addingTimeInterval(60))
        selected.exerciseSession = session
        let deadline = session.deadline(for: exercise)!
        XCTAssertEqual(selected.activeUntil, deadline.addingTimeInterval(600))
        XCTAssertTrue(selected.isActive(at: deadline))
        XCTAssertFalse(selected.isActive(at: deadline.addingTimeInterval(600)))
        session.pause(at: now.addingTimeInterval(70))
        selected.exerciseSession = session
        XCTAssertEqual(selected.activeUntil, now.addingTimeInterval(670))
        session.endedAt = now.addingTimeInterval(90)
        selected.exerciseSession = session
        XCTAssertEqual(selected.activeUntil, now.addingTimeInterval(690))
        selected.completedAt = now.addingTimeInterval(100)
        XCTAssertFalse(selected.isActive(at: now.addingTimeInterval(100)))
    }

    func testComplicationReleasesUnfinishedBreakWithoutAnotherCheck() {
        var snapshot = ComplicationSnapshot(generatedAt: now, monitoring: true, checkedAt: now)
        snapshot.activeExerciseTitle = "Mobility flow"
        snapshot.activeExerciseExpiresAt = now.addingTimeInterval(60)
        XCTAssertEqual(snapshot.title(at: now), "Your movement break")
        XCTAssertEqual(snapshot.detail(at: now), "Mobility flow")
        XCTAssertTrue(snapshot.transitionDates(after: now).contains(now.addingTimeInterval(60)))
        XCTAssertEqual(snapshot.title(at: now.addingTimeInterval(60)), "Watching for a moment")
        XCTAssertNotEqual(snapshot.detail(at: now.addingTimeInterval(60)), "Mobility flow")
        snapshot.activeExerciseExpiresAt = nil
        XCTAssertNotEqual(snapshot.detail(at: now.addingTimeInterval(600)), "Mobility flow")
    }

    func testIgnoredBreakIsPersistedOnceAndCountsAsMiss() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("study.json")
        let store = try StudyStore(url: url)
        var selected = prompt()
        selected.status = .selected
        selected.selectedExerciseID = selected.options[0].id
        selected.respondedAt = now
        selected.scheduledAt = now
        var older = prompt(seed: 2)
        older.status = .expired
        older.scheduledAt = now.addingTimeInterval(-60)
        try store.transaction { $0.prompts = [older, selected] }
        try store.expire(at: now.addingTimeInterval(599))
        XCTAssertEqual(store.state.prompts[1].status, .selected)
        try store.expire(at: now.addingTimeInterval(600))
        try store.expire(at: now.addingTimeInterval(601))
        let reloaded = try StudyStore(url: url)
        let ignored = reloaded.state.prompts[1]
        XCTAssertEqual(ignored.status, .ignored)
        XCTAssertEqual(ignored.selectedExerciseID, selected.selectedExerciseID)
        XCTAssertNil(ignored.completedAt)
        XCTAssertNil(ignored.abandonedAt)
        XCTAssertEqual(reloaded.state.events.filter { $0.kind == "ignored_break" }.count, 1)
        XCTAssertEqual(ReminderPlanning.cooldownEnd(settings: settings(), history: reloaded.state.prompts,
                                                   at: now.addingTimeInterval(601), calendar: ReminderPlanning.calendar(for: context())),
                       now.addingTimeInterval(Double(settings().cooldownMinutes) * 60 * 1.5))
    }

    func testReselectionKeepsOriginalOptionsAndRejectsExpiredBreak() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try StudyStore(url: directory.appendingPathComponent("study.json"))
        var selected = prompt()
        selected.status = .selected
        selected.selectedExerciseID = selected.options[0].id
        selected.respondedAt = now
        selected.exerciseSession = ExerciseSession(startedAt: now, runningSince: now)
        try store.transaction { $0.prompts = [selected] }
        try store.reselect(promptID: selected.id, exerciseID: selected.options[1].id, at: now.addingTimeInterval(30))
        XCTAssertEqual(store.state.prompts[0].options.map(\.id), selected.options.map(\.id))
        XCTAssertEqual(store.state.prompts[0].selectedExerciseID, selected.options[1].id)
        XCTAssertNil(store.state.prompts[0].exerciseSession)
        XCTAssertThrowsError(try store.reselect(promptID: selected.id, exerciseID: selected.options[2].id, at: now.addingTimeInterval(630)))
    }

    func testAvailableSedentaryMomentQualifies() {
        let decision = OpportunityEngine.evaluate(context(), settings: settings(), history: [])
        XCTAssertTrue(decision.shouldNotify)
        XCTAssertEqual(decision.inactivityMinutes, 60)
        XCTAssertEqual(decision.score, decision.scoreContributions.values.reduce(0, +))
    }

    func testMissingOrStaleHealthNeverMeansInactivity() {
        var value = context()
        value.heartRate = nil
        XCTAssertNil(value.inactivityEstimate)
        XCTAssertFalse(OpportunityEngine.evaluate(value, settings: settings(), history: []).shouldNotify)
        value.heartRate = .init(value: 60, date: now.addingTimeInterval(-3600))
        XCTAssertNil(value.inactivityEstimate)
        value = context()
        value.motion = .unknown
        value.stepsRecent = nil
        value.lastMovement = now.addingTimeInterval(-7200)
        XCTAssertNil(value.inactivityEstimate)
    }

    func testRecentMovementOverridesStationaryEstimate() {
        var value = context()
        value.lastMovement = now.addingTimeInterval(-5 * 60)
        XCTAssertEqual(value.inactivityEstimate, 5)
        XCTAssertFalse(OpportunityEngine.evaluate(value, settings: settings(), history: []).shouldNotify)
    }

    func testCalendarAndTimeGates() {
        var value = context()
        value.busy = true
        XCTAssertFalse(OpportunityEngine.evaluate(value, settings: settings(), history: []).shouldNotify)
        value = context()
        value.calendarAvailable = false
        value.freeMinutes = nil
        XCTAssertFalse(OpportunityEngine.evaluate(value, settings: settings(), history: []).shouldNotify)
        var preferences = settings()
        preferences.requireCalendar = false
        XCTAssertFalse(OpportunityEngine.evaluate(value, settings: preferences, history: []).shouldNotify)
        value = context()
        value.freeMinutes = 6
        XCTAssertFalse(OpportunityEngine.evaluate(value, settings: settings(), history: []).shouldNotify)
        value = context()
        value.localHour = 23
        XCTAssertFalse(OpportunityEngine.evaluate(value, settings: settings(), history: []).shouldNotify)
        preferences.startHour = 22
        preferences.endHour = 6
        XCTAssertTrue(OpportunityEngine.evaluate(value, settings: preferences, history: []).shouldNotify)
        value.localHour = 12
        XCTAssertFalse(OpportunityEngine.evaluate(value, settings: preferences, history: []).shouldNotify)
    }

    func testMotionRecoveryAndBatterySuppressReminders() {
        let changes: [(inout ContextSnapshot) -> Void] = [
            { $0.motion = .automotive }, { $0.motion = .walking }, { $0.motion = .running },
            { $0.charging = true }, { $0.lowPower = true }, { $0.batteryLevel = 0.1 },
            { $0.heartRate = .init(value: 130, date: self.now) },
            { $0.sleepHours = 3 }, { $0.lastWorkoutEnd = self.now.addingTimeInterval(-600) }
        ]
        for change in changes {
            var value = context()
            change(&value)
            XCTAssertFalse(OpportunityEngine.evaluate(value, settings: settings(), history: []).shouldNotify)
        }
    }

    func testCooldownAndNonResponseBackoff() {
        var history = prompt()
        history.status = .dismissed
        history.scheduledAt = now.addingTimeInterval(-80 * 60)
        let result = OpportunityEngine.evaluate(context(), settings: settings(), history: [history])
        XCTAssertFalse(result.reasons.contains("Reminder cooldown is active"))
        history.status = .selected
        history.completedAt = now.addingTimeInterval(-75 * 60)
        XCTAssertTrue(OpportunityEngine.evaluate(context(), settings: settings(), history: [history]).shouldNotify)
    }

    func testDailyLimitUsesLocalDayAndFailedRequestsDoNotCount() {
        var preferences = settings()
        preferences.dailyLimit = 1
        preferences.cooldownMinutes = 1
        var history = prompt()
        history.status = .dismissed
        history.scheduledAt = now.addingTimeInterval(-3600)
        XCTAssertTrue(OpportunityEngine.evaluate(context(), settings: preferences, history: [history]).reasons.contains("Daily reminder limit reached"))
        history.status = .failed
        history.scheduledAt = nil
        XCTAssertTrue(OpportunityEngine.evaluate(context(), settings: preferences, history: [history]).shouldNotify)
    }

    func testUnlimitedDailyLimitAllowsMoreThanTenRemindersAndPersists() throws {
        var preferences = settings()
        preferences.dailyLimit = Settings.unlimitedDailyLimit
        preferences.cooldownMinutes = 0
        var prior = prompt()
        prior.status = .dismissed
        prior.scheduledAt = now.addingTimeInterval(-3600)
        let history = Array(repeating: prior, count: 11)
        XCTAssertTrue(OpportunityEngine.evaluate(context(), settings: preferences, history: history).shouldNotify)
        let restored = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(preferences))
        XCTAssertEqual(restored.dailyLimit, Settings.unlimitedDailyLimit)
        preferences.dailyLimit = 10
        XCTAssertTrue(OpportunityEngine.evaluate(context(), settings: preferences, history: history).reasons.contains("Daily reminder limit reached"))
        preferences.dailyLimit = Settings.unlimitedDailyLimit
        var busyContext = context()
        busyContext.busy = true
        XCTAssertFalse(OpportunityEngine.evaluate(busyContext, settings: preferences, history: history).shouldNotify)
    }

    func testExactlyThreeOrderedOptionsAndColdStartLabels() {
        let invitation = prompt()
        XCTAssertEqual(invitation.options.map(\.exercise.effort), [.easy, .moderate, .challenge])
        XCTAssertEqual(Set(invitation.options.map(\.id)).count, 3)
        XCTAssertEqual(invitation.method, .coldStartRandom)
        XCTAssertEqual(invitation.methodProbability, 1)
        XCTAssertTrue(invitation.options.allSatisfy { $0.selectionProbability == 1.0 / 3.0 })
    }

    func testLearningFavorsChosenOptionAndExplorationIgnoresPreferences() {
        var prior = prompt()
        prior.scheduledAt = now.addingTimeInterval(-86400)
        prior.status = .selected
        prior.selectedExerciseID = prior.options[0].id
        prior.completedAt = now
        let history = Array(repeating: prior, count: 10)
        var preferences = settings()
        preferences.explorationRate = 0
        let learned = prompt(settings: preferences, history: history)
        XCTAssertEqual(learned.method, .learned)
        XCTAssertEqual(learned.options[0].id, prior.selectedExerciseID)
        XCTAssertEqual(learned.options[0].selectionProbability, 1)
        preferences.explorationRate = 1
        var otherPrior = prior
        otherPrior.selectedExerciseID = Exercise.catalog.first { $0.effort == .easy && $0.id != prior.selectedExerciseID }!.id
        var unique: Set<String> = []
        for seed in 1...100 {
            let random = prompt(settings: preferences, history: history, seed: UInt64(seed))
            let other = prompt(settings: preferences, history: [otherPrior], seed: UInt64(seed))
            XCTAssertEqual(random.method, .randomExploration)
            XCTAssertEqual(random.options.map(\.id), other.options.map(\.id))
            XCTAssertEqual(random.options[0].selectionProbability, 1.0 / 3.0)
            unique.insert(random.options[0].id)
        }
        XCTAssertEqual(unique.count, 3)
    }

    func testExcludedExercisesAndInsufficientTimeProduceNoInvalidSlate() {
        var preferences = settings()
        preferences.excludedExerciseIDs = Set(Exercise.catalog.filter { $0.effort == .challenge }.map(\.id))
        var rng = SeededRandom(seed: 1)
        let decision = OpportunityDecision(shouldNotify: true, score: 80, reasons: [], availableMinutes: 30)
        XCTAssertNil(RecommendationEngine.makePrompt(context: context(), decision: decision, settings: preferences, history: [], rng: &rng))
        let short = OpportunityDecision(shouldNotify: true, score: 80, reasons: [], availableMinutes: 4)
        XCTAssertNil(RecommendationEngine.makePrompt(context: context(), decision: short, settings: settings(), history: [], rng: &rng))
        preferences = settings()
        preferences.excludedExerciseIDs = ["shoulders"]
        XCTAssertFalse(prompt(settings: preferences).options.contains { $0.id == "shoulders" })
    }

    func testPersistenceIdempotencyExpiryAndExports() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("study.json")
        let store = try StudyStore(url: url)
        var invitation = prompt()
        invitation.status = .scheduled
        invitation.scheduledAt = now
        try store.transaction { $0.prompts.append(invitation) }
        let chosen = invitation.options[1].id
        XCTAssertTrue(try store.respond(promptID: invitation.id, exerciseID: chosen, source: "test", at: now))
        XCTAssertFalse(try store.respond(promptID: invitation.id, exerciseID: invitation.options[0].id, source: "test", at: now))
        XCTAssertEqual(store.state.events.filter { $0.kind == "selected" }.count, 1)
        XCTAssertNil(store.state.prompts[0].completedAt)
        try store.finish(promptID: invitation.id, completed: true, at: now.addingTimeInterval(180))
        try store.finish(promptID: invitation.id, completed: true, at: now.addingTimeInterval(190))
        XCTAssertEqual(store.state.events.filter { $0.kind == "completed_self_report" }.count, 1)
        let reloaded = try StudyStore(url: url)
        XCTAssertEqual(reloaded.state.prompts[0].selectedExerciseID, chosen)
        XCTAssertEqual(reloaded.state.participantID, store.state.participantID)
        let exported = try reloaded.export(to: directory.appendingPathComponent("export"))
        XCTAssertEqual(exported.count, 3)
        let csv = try String(contentsOf: exported[1], encoding: .utf8)
        XCTAssertEqual(csv.split(separator: "\n").count, 4)
        XCTAssertTrue(csv.contains("coldStartRandom"))
        XCTAssertEqual(try StudyStore.decoder.decode(StudyState.self, from: Data(contentsOf: exported[0])).prompts.count, 1)
        var expired = prompt(seed: 2)
        expired.status = .scheduled
        try store.transaction { $0.prompts.append(expired) }
        XCTAssertThrowsError(try store.respond(promptID: expired.id, exerciseID: expired.options[0].id, source: "test", at: now.addingTimeInterval(3600)))
        try store.expire(at: now.addingTimeInterval(3600))
        XCTAssertEqual(store.state.prompts[1].status, .expired)
        XCTAssertEqual(store.state.events.last?.kind, "expired_no_response")
    }

    func testCorruptFileIsNotOverwrittenAndFailedSaveDoesNotPublish() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let corrupt = directory.appendingPathComponent("corrupt.json")
        try Data("not json".utf8).write(to: corrupt)
        XCTAssertThrowsError(try StudyStore(url: corrupt))
        XCTAssertEqual(try String(contentsOf: corrupt, encoding: .utf8), "not json")
        let blockedParent = directory.appendingPathComponent("parent")
        let store = try StudyStore(url: blockedParent.appendingPathComponent("study.json"))
        try Data("file, not a directory".utf8).write(to: blockedParent)
        XCTAssertThrowsError(try store.transaction { $0.settings.monitoring = true })
        XCTAssertFalse(store.state.settings.monitoring)
    }

    func testResearchEventsKeepSequenceParticipantSessionAndMillisecondTimes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("study.json")
        let store = try StudyStore(url: url)
        let session = UUID()
        store.sessionID = session
        let timestamp = now.addingTimeInterval(0.123)
        try store.transaction { state in
            state.settings.explorationRate = 0.5
            state.events.append(.init(date: timestamp, kind: "first", source: "test"))
            state.events.append(.init(date: timestamp, kind: "second", source: "test"))
        }
        let reloaded = try StudyStore(url: url)
        XCTAssertEqual(reloaded.state.events.map(\.sequence), [1, 2])
        XCTAssertEqual(reloaded.state.events[0].participantID, store.state.participantID)
        XCTAssertEqual(reloaded.state.events[0].sessionID, session)
        XCTAssertEqual(reloaded.state.events[0].settings?.explorationRate, 0.5)
        XCTAssertEqual(reloaded.state.events[0].date.timeIntervalSince(timestamp), 0, accuracy: 0.001)
        let exported = try reloaded.export(to: directory.appendingPathComponent("export"))
        let lines = try String(contentsOf: exported[2], encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(try StudyStore.decoder.decode(StudyEvent.self, from: Data(lines[1].utf8)).sequence, 2)
    }

    func testRecordedSeedReplaysSlateAndConditionalProbability() {
        let seed: UInt64 = 18446744073709551614
        var first = StudyRandom(seed: seed)
        var second = StudyRandom(seed: seed)
        let decision = OpportunityEngine.evaluate(context(), settings: settings(), history: [])
        let a = RecommendationEngine.makePrompt(context: context(), decision: decision, settings: settings(), history: [], randomizationSeed: String(seed), rng: &first)!
        let b = RecommendationEngine.makePrompt(context: context(), decision: decision, settings: settings(), history: [], randomizationSeed: String(seed), rng: &second)!
        XCTAssertEqual(a.options.map(\.id), b.options.map(\.id))
        XCTAssertEqual(a.randomizationSeed, String(seed))
        XCTAssertEqual(a.slateAssignmentProbability, 1.0 / 27, accuracy: 0.000001)
        XCTAssertTrue(a.options.allSatisfy { $0.exposureCounts.values.allSatisfy { $0 == 0 } })
    }

    func testNotificationResponseRecoversInterruptedSchedulingForLearning() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try StudyStore(url: directory.appendingPathComponent("study.json"))
        let invitation = prompt()
        try store.transaction { $0.prompts.append(invitation) }
        XCTAssertNil(store.state.prompts[0].scheduledAt)
        XCTAssertTrue(try store.respond(promptID: invitation.id, exerciseID: invitation.options[0].id, source: "notification", at: now))
        XCTAssertNotNil(store.state.prompts[0].scheduledAt)
        XCTAssertTrue(store.state.events.contains { $0.kind == "schedule_evidence_from_response" })
        var preferences = settings()
        preferences.explorationRate = 0
        XCTAssertEqual(prompt(settings: preferences, history: store.state.prompts).method, .learned)
    }
}

private struct SeededRandom: RandomNumberGenerator {
    var seed: UInt64
    mutating func next() -> UInt64 {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return seed
    }
}
