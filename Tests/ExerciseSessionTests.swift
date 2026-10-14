import XCTest
@testable import ExerciseAnalyserCore

final class ExerciseSessionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_626_400)
    private func exercise(_ id: String) -> Exercise { Exercise.catalog.first { $0.id == id }! }

    func testReadySessionNeverCountsDownUntilPlay() {
        let session = ExerciseSession()
        XCTAssertEqual(session.remaining(for: exercise("shoulders"), at: now.addingTimeInterval(600)), 60)
        XCTAssertNil(session.deadline(for: exercise("shoulders")))
        XCTAssertNil(session.startedAt)
    }

    func testPauseResumeExcludesPausedTimeAndStartIsIdempotent() {
        var session = ExerciseSession()
        session.start(at: now)
        session.start(at: now.addingTimeInterval(5))
        session.pause(at: now.addingTimeInterval(20))
        session.pause(at: now.addingTimeInterval(30))
        XCTAssertEqual(session.remaining(for: exercise("shoulders"), at: now.addingTimeInterval(600)), 40)
        session.start(at: now.addingTimeInterval(600))
        XCTAssertEqual(session.deadline(for: exercise("shoulders")), now.addingTimeInterval(640))
        XCTAssertEqual(session.remaining(for: exercise("shoulders"), at: now.addingTimeInterval(610)), 30)
    }

    func testDelayedWakeClampsEvidenceWindowAndEndsOnlyOnce() {
        var session = ExerciseSession()
        session.start(at: now)
        XCTAssertFalse(session.endIfDue(for: exercise("shoulders"), at: now.addingTimeInterval(59.1)))
        XCTAssertEqual(session.remaining(for: exercise("shoulders"), at: now.addingTimeInterval(59.1)), 1)
        XCTAssertTrue(session.endIfDue(for: exercise("shoulders"), at: now.addingTimeInterval(600)))
        XCTAssertEqual(session.endedAt, now.addingTimeInterval(60))
        XCTAssertEqual(session.intervals.first?.duration, 60)
        XCTAssertFalse(session.endIfDue(for: exercise("shoulders"), at: now.addingTimeInterval(700)))
        session.start(at: now.addingTimeInterval(800))
        XCTAssertNil(session.runningSince)
    }

    func testTimerSurvivesPersistenceWhileRunningAndPaused() throws {
        var session = ExerciseSession()
        session.start(at: now)
        let restored = try StudyStore.decoder.decode(ExerciseSession.self, from: StudyStore.encoder.encode(session))
        XCTAssertEqual(restored.remaining(for: exercise("shoulders"), at: now.addingTimeInterval(30)), 30)
        session.pause(at: now.addingTimeInterval(15))
        let paused = try StudyStore.decoder.decode(ExerciseSession.self, from: StudyStore.encoder.encode(session))
        XCTAssertEqual(paused.remaining(for: exercise("shoulders"), at: now.addingTimeInterval(600)), 45)
    }

    func testWalkingUsesStepsOrDistanceButNotWristMotion() {
        let walk = exercise("walk")
        XCTAssertEqual(ExerciseAssessment.evaluate(exercise: walk, evidence: .init(steps: 60)).outcome, .movementDetected)
        XCTAssertEqual(ExerciseAssessment.evaluate(exercise: walk, evidence: .init(distanceMeters: 30)).outcome, .movementDetected)
        XCTAssertEqual(ExerciseAssessment.evaluate(exercise: walk, evidence: .init(wristMovementSeconds: 180, wristObservedSeconds: 180)).outcome, .inconclusive)
        XCTAssertEqual(ExerciseAssessment.evaluate(exercise: walk, evidence: .init(steps: 0)).outcome, .littleMovement)
    }

    func testWristChecksDistinguishMissingCoverageFromLittleMovement() {
        let shoulder = exercise("shoulders")
        XCTAssertEqual(ExerciseAssessment.evaluate(exercise: shoulder, evidence: .init()).outcome, .inconclusive)
        XCTAssertEqual(ExerciseAssessment.evaluate(exercise: shoulder, evidence: .init(wristMovementSeconds: 8, wristObservedSeconds: 60)).outcome, .movementDetected)
        XCTAssertEqual(ExerciseAssessment.evaluate(exercise: shoulder, evidence: .init(wristMovementSeconds: 2, wristObservedSeconds: 60)).outcome, .littleMovement)
        XCTAssertEqual(ExerciseAssessment.evaluate(exercise: shoulder, evidence: .init(wristMovementSeconds: 2, wristObservedSeconds: 10)).outcome, .inconclusive)
    }

    func testExerciseSpecificChecksAndAnklesStayInconclusive() {
        XCTAssertEqual(ExerciseAssessment.evaluate(exercise: exercise("march"), evidence: .init(steps: 80)).outcome, .movementDetected)
        XCTAssertEqual(ExerciseAssessment.evaluate(exercise: exercise("sit_stand"), evidence: .init(steps: 80)).outcome, .inconclusive)
        XCTAssertEqual(ExerciseAssessment.evaluate(exercise: exercise("ankles"), evidence: .init(steps: 100, wristMovementSeconds: 60, wristObservedSeconds: 60)).outcome, .inconclusive)
    }

    func testOldPromptsDecodeWithoutSessionAndSelectionDoesNotStartTimer() throws {
        let fixture = ExerciseAnalyserCoreTests().prompt()
        let data = try StudyStore.encoder.encode(fixture)
        let restored = try StudyStore.decoder.decode(ExercisePrompt.self, from: data)
        XCTAssertNil(restored.exerciseSession)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try StudyStore(url: directory.appendingPathComponent("study.json"))
        try store.transaction { $0.prompts.append(fixture) }
        try store.respond(promptID: fixture.id, exerciseID: fixture.options[0].id, source: "notification", at: fixture.createdAt)
        XCTAssertEqual(store.state.prompts[0].status, .selected)
        XCTAssertNil(store.state.prompts[0].exerciseSession?.startedAt)
        XCTAssertNil(store.state.prompts[0].completedAt)
    }
}
