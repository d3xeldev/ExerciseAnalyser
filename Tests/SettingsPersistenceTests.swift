import XCTest
@testable import ExerciseAnalyserCore

final class SettingsPersistenceTests: XCTestCase {
    @MainActor
    func testSettingsCommitDoesNotRewriteHistoryAndReplaysBetweenEvents() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try StudyStore(url: url)
        var prompt = ExerciseAnalyserCoreTests().prompt()
        prompt.status = .scheduled
        try store.transaction {
            $0.prompts.append(prompt)
            for _ in 0..<5_000 { $0.events.append(.init(date: Date(), kind: "history", source: "test")) }
        }
        let snapshot = try Data(contentsOf: url)
        try store.appendEvent(.init(date: Date(), kind: "before", source: "test"))
        var settings = store.state.settings
        settings.monitoring = false
        settings.cooldownMinutes = 17
        try await store.saveSettings(settings)
        try store.appendEvent(.init(date: Date(), kind: "after", source: "test"))
        XCTAssertEqual(try Data(contentsOf: url), snapshot)
        let records = try FileManager.default.contentsOfDirectory(at: url.appendingPathExtension("settings"), includingPropertiesForKeys: nil)
        XCTAssertEqual(records.count, 1)
        XCTAssertLessThan(try Data(contentsOf: records[0]).count, 20_000)
        let restored = try StudyStore(url: url)
        XCTAssertEqual(restored.state.settings, settings)
        XCTAssertEqual(restored.state.prompts[0].status, .cancelled)
        XCTAssertNotNil(restored.state.prompts[0].cancelledAt)
        XCTAssertEqual(Array(restored.state.events.suffix(4)).map(\.kind), ["before", "settings_changed", "cancelled_settings_changed", "after"])
        XCTAssertEqual(restored.state.events.map(\.sequence), (1...5_004).map { Optional($0) })
        // Cleanup interrupted after a snapshot must not replay an old settings change.
        let oldCommit = try Data(contentsOf: records[0])
        try restored.transaction { $0.settings.cooldownMinutes = 99 }
        try FileManager.default.createDirectory(at: url.appendingPathExtension("settings"), withIntermediateDirectories: true)
        try oldCommit.write(to: records[0])
        XCTAssertEqual(try StudyStore(url: url).state.settings.cooldownMinutes, 99)
    }

    @MainActor
    func testConcurrentEventAndRepeatedSettingsArePreserved() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try StudyStore(url: url)
        try store.transaction { _ in }
        var settings = store.state.settings
        settings.monitoring = true
        let requested = settings
        let save = Task { try await store.saveSettings(requested) }
        await Task.yield()
        try store.appendEvent(.init(date: Date(), kind: "concurrent", source: "test"))
        try await save.value
        settings.monitoring = false
        try await store.saveSettings(settings)
        let restored = try StudyStore(url: url)
        XCTAssertFalse(restored.state.settings.monitoring)
        XCTAssertEqual(restored.state.events.filter { $0.kind == "settings_changed" }.count, 2)
        XCTAssertEqual(restored.state.events.filter { $0.kind == "concurrent" }.count, 1)
        XCTAssertEqual(restored.state.events.map(\.sequence), [1, 2, 3])
    }

    @MainActor
    func testFailedSettingsWriteDoesNotPublishOrCancelInvitations() async throws {
        let url = location()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = try StudyStore(url: url)
        var prompt = ExerciseAnalyserCoreTests().prompt()
        prompt.status = .scheduled
        try store.transaction { $0.prompts.append(prompt) }
        let original = store.state.settings
        var updated = original
        updated.monitoring.toggle()
        try Data().write(to: url.appendingPathExtension("settings"))
        do {
            try await store.saveSettings(updated)
            XCTFail("Expected the settings journal write to fail")
        } catch {
            XCTAssertEqual(store.state.settings, original)
            XCTAssertEqual(store.state.prompts[0].status, .scheduled)
            XCTAssertTrue(store.state.events.isEmpty)
        }
    }

    private func location() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("study.json")
    }
}
