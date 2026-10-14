import XCTest
@testable import ExerciseAnalyserCore

final class StudyJournalTests: XCTestCase {
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
