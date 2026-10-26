import XCTest
@testable import ExerciseAnalyserCore

final class StudyJournalTests: XCTestCase {
    func testTimerTransitionsReplayWithoutRewritingHistory() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try StudyStore(url: url)
        var prompt = ExerciseAnalyserCoreTests().prompt()
        prompt.status = .selected
        prompt.selectedExerciseID = prompt.options[0].id
        try store.transaction {
            $0.prompts.append(prompt)
            for _ in 0..<1_000 { $0.events.append(.init(date: prompt.createdAt, kind: "history", source: "test")) }
        }
        let snapshot = try Data(contentsOf: url)
        var session = ExerciseSession()
        session.start(at: prompt.createdAt)
        try store.saveSession(session, promptID: prompt.id, kind: "exercise_started")
        XCTAssertEqual(try StudyStore(url: url).state.prompts[0].exerciseSession?.runningSince, session.runningSince)
        session.pause(at: prompt.createdAt.addingTimeInterval(10))
        try store.saveSession(session, promptID: prompt.id, kind: "exercise_paused")
        session.start(at: prompt.createdAt.addingTimeInterval(20))
        try store.saveSession(session, promptID: prompt.id, kind: "exercise_resumed")
        let exercise = prompt.options[0].exercise
        XCTAssertTrue(session.endIfDue(for: exercise, at: session.deadline(for: exercise)!))
        try store.saveSession(session, promptID: prompt.id, kind: "exercise_timer_ended")
        session.assessment = .evaluate(exercise: exercise, evidence: .init())
        try store.saveSession(session, promptID: prompt.id, kind: "exercise_movement_assessed")
        XCTAssertEqual(try Data(contentsOf: url), snapshot)
        let restored = try StudyStore(url: url)
        XCTAssertEqual(restored.state.prompts[0].exerciseSession?.endedAt, session.endedAt)
        XCTAssertEqual(restored.state.prompts[0].exerciseSession?.intervals, session.intervals)
        XCTAssertEqual(restored.state.prompts[0].exerciseSession?.assessment?.outcome, session.assessment?.outcome)
        XCTAssertEqual(restored.state.events.count, 1_005)

        let journal = url.appendingPathExtension("events.jsonl")
        let oldJournal = try Data(contentsOf: journal)
        try restored.transaction { $0.prompts[0].exerciseSession = nil }
        // A stale journal after snapshot commit must not resurrect the previous timer.
        try oldJournal.write(to: journal)
        XCTAssertNil(try StudyStore(url: url).state.prompts[0].exerciseSession)
    }

    func testFailedTimerSaveDoesNotPublishSessionOrEvent() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try StudyStore(url: url)
        let prompt = ExerciseAnalyserCoreTests().prompt()
        try store.transaction { $0.prompts.append(prompt) }
        try FileManager.default.createDirectory(at: url.appendingPathExtension("events.jsonl"), withIntermediateDirectories: false)
        var session = ExerciseSession()
        session.start(at: prompt.createdAt)
        XCTAssertThrowsError(try store.saveSession(session, promptID: prompt.id, kind: "exercise_started"))
        XCTAssertNil(store.state.prompts[0].exerciseSession)
        XCTAssertTrue(store.state.events.isEmpty)
    }

    @MainActor
    func testAsyncManualPromptPreservesJournalAndConcurrentChanges() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try StudyStore(url: url)
        try store.transaction {
            for _ in 0..<1_000 { $0.events.append(.init(date: Date(), kind: "history", source: "test")) }
        }
        let prompt = ExerciseAnalyserCoreTests().prompt()
        let saving = Task { try await store.appendManualPrompt(prompt) }
        await Task.yield()
        try store.appendEvent(.init(date: Date(), kind: "concurrent_event", source: "test"))
        try store.transaction { $0.settings.cooldownMinutes = 42 }
        try await saving.value
        let restored = try StudyStore(url: url)
        XCTAssertEqual(restored.state.prompts.map(\.id), [prompt.id])
        XCTAssertEqual(restored.state.settings.cooldownMinutes, 42)
        XCTAssertEqual(restored.state.events.filter { $0.kind == "concurrent_event" }.count, 1)
        XCTAssertEqual(restored.state.events.filter { $0.kind == "manual_intervention" }.count, 1)
        XCTAssertEqual(restored.state.events.map(\.sequence), (1...1_002).map { Optional($0) })
    }

    @MainActor
    func testCancelledManualPromptDoesNotPublish() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try StudyStore(url: url)
        let saving = Task { try await store.appendManualPrompt(ExerciseAnalyserCoreTests().prompt()) }
        saving.cancel()
        do {
            try await saving.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertTrue(store.state.prompts.isEmpty)
            XCTAssertTrue(store.state.events.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @MainActor
    func testFailedAsyncManualPromptDoesNotPublish() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try StudyStore(url: directory.appendingPathComponent("study.json"))
        try Data().write(to: directory)
        do {
            try await store.appendManualPrompt(ExerciseAnalyserCoreTests().prompt())
            XCTFail("Expected the save to fail")
        } catch {
            XCTAssertTrue(store.state.prompts.isEmpty)
            XCTAssertTrue(store.state.events.isEmpty)
        }
    }

    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("study.json")
    }

    func testJournalPersistsEventsWithoutRewritingSnapshot() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try StudyStore(url: url)
        try store.transaction { $0.settings.monitoring = true }
        let snapshot = try Data(contentsOf: url)
        let session = UUID()
        store.sessionID = session
        for _ in 0..<50 { try store.appendEvent(.init(date: Date(), kind: "health_observer_received", source: "test")) }
        XCTAssertEqual(try Data(contentsOf: url), snapshot)
        let restored = try StudyStore(url: url)
        XCTAssertEqual(restored.state.events.count, 50)
        XCTAssertEqual(restored.state.events.last?.sequence, 50)
        XCTAssertEqual(restored.state.events.last?.sessionID, session)
        XCTAssertEqual(restored.state.events.last?.participantID, restored.state.participantID)
        XCTAssertEqual(restored.state.events.last?.settings?.monitoring, true)
        let exports = try restored.export(to: url.deletingLastPathComponent().appendingPathComponent("export"))
        let exported = try StudyStore.decoder.decode(StudyState.self, from: Data(contentsOf: exports[0]))
        XCTAssertEqual(exported.events.count, 50)
    }

    func testSnapshotCommitAndJournalReplayAreIdempotent() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try StudyStore(url: url)
        try store.appendEvent(.init(date: Date(), kind: "first", source: "test"))
        let journal = url.appendingPathExtension("events.jsonl")
        let oldJournal = try Data(contentsOf: journal)
        try store.transaction { $0.settings.cooldownMinutes = 15 }
        // Simulate a crash after the atomic snapshot replacement but before journal cleanup.
        try oldJournal.write(to: journal)
        let restored = try StudyStore(url: url)
        XCTAssertEqual(restored.state.events.count, 1)
        XCTAssertEqual(restored.state.settings.cooldownMinutes, 15)
        try restored.appendEvent(.init(date: Date(), kind: "second", source: "test"))
        let again = try StudyStore(url: url)
        XCTAssertEqual(again.state.events.map(\.kind), ["first", "second"])
        XCTAssertEqual(again.state.events.last?.sequence, 2)
    }

    func testInterruptedTailCanRecoverWithoutLosingCompleteEvents() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try StudyStore(url: url)
        try store.appendEvent(.init(date: Date(), kind: "first", source: "test"))
        let journal = url.appendingPathExtension("events.jsonl")
        var bytes = try Data(contentsOf: journal)
        bytes.append(Data("{\"partial\":".utf8))
        try bytes.write(to: journal)
        let restored = try StudyStore(url: url)
        XCTAssertEqual(restored.state.events.count, 1)
        try restored.appendEvent(.init(date: Date(), kind: "second", source: "test"))
        XCTAssertEqual(try StudyStore(url: url).state.events.map(\.kind), ["first", "second"])
    }

    func testCompleteCorruptRecordFailsClosed() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try StudyStore(url: url)
        try store.appendEvent(.init(date: Date(), kind: "first", source: "test"))
        let journal = url.appendingPathExtension("events.jsonl")
        var bytes = try Data(contentsOf: journal)
        bytes.append(Data("invalid-record\n".utf8))
        try bytes.write(to: journal)
        XCTAssertThrowsError(try StudyStore(url: url))
        XCTAssertEqual(try Data(contentsOf: journal), bytes)
    }

    func testFailedAppendDoesNotPublishEvent() throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try StudyStore(url: url)
        try store.transaction { _ in }
        try FileManager.default.createDirectory(at: url.appendingPathExtension("events.jsonl"), withIntermediateDirectories: false)
        XCTAssertThrowsError(try store.appendEvent(.init(date: Date(), kind: "failed", source: "test")))
        XCTAssertTrue(store.state.events.isEmpty)
    }
}
