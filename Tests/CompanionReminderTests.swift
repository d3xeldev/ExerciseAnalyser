import XCTest
@testable import ExerciseAnalyserCore

final class CompanionReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testImmediateAndQueuedCopiesOnlyAlertOnceAfterRelaunch() throws {
        let id = UUID()
        var ledger = CompanionReminderLedger()
        XCTAssertTrue(ledger.accepts(id: id, version: now, expiresAt: now.addingTimeInterval(600), now: now))
        ledger.record(id: id, version: now, now: now)
        let restored = try JSONDecoder().decode(CompanionReminderLedger.self, from: JSONEncoder().encode(ledger))
        XCTAssertFalse(restored.accepts(id: id, version: now, expiresAt: now.addingTimeInterval(600), now: now.addingTimeInterval(10)))
    }

    func testCancellationArrivingBeforeOriginalReminderPreventsAlert() {
        let id = UUID()
        var ledger = CompanionReminderLedger()
        ledger.record(id: id, version: now.addingTimeInterval(5), now: now.addingTimeInterval(5))
        XCTAssertFalse(ledger.accepts(id: id, version: now, expiresAt: now.addingTimeInterval(600), now: now.addingTimeInterval(10)))
    }

    func testNewSnoozeReplacesEarlierReminderButOldCancellationCannotRemoveIt() {
        let id = UUID()
        var ledger = CompanionReminderLedger()
        ledger.record(id: id, version: now, now: now)
        let snoozedAt = now.addingTimeInterval(30)
        XCTAssertTrue(ledger.accepts(id: id, version: snoozedAt, expiresAt: now.addingTimeInterval(900), now: snoozedAt))
        ledger.record(id: id, version: snoozedAt, now: snoozedAt)
        XCTAssertFalse(ledger.accepts(id: id, version: now.addingTimeInterval(10), expiresAt: now.addingTimeInterval(900), now: snoozedAt))
    }

    func testExpiredAndDayOldTransfersAreRejectedEvenWithoutLedgerEntry() {
        let ledger = CompanionReminderLedger()
        XCTAssertFalse(ledger.accepts(id: UUID(), version: now, expiresAt: now, now: now))
        XCTAssertFalse(ledger.accepts(id: UUID(), version: now.addingTimeInterval(-86400), expiresAt: now.addingTimeInterval(600), now: now))
        XCTAssertFalse(ledger.accepts(id: UUID(), version: now.addingTimeInterval(120), expiresAt: now.addingTimeInterval(600), now: now))
    }

    func testPruningKeepsCancellationUntilAllOlderPacketsAreTooOld() {
        let id = UUID()
        var ledger = CompanionReminderLedger()
        ledger.record(id: id, version: now, now: now)
        let later = now.addingTimeInterval(26 * 3600)
        ledger.record(id: UUID(), version: later, now: later)
        XCTAssertNil(ledger.entries[id.uuidString])
        XCTAssertFalse(ledger.accepts(id: id, version: now, expiresAt: later.addingTimeInterval(600), now: later))
    }

    func testReminderWireRoundTripPreservesSnoozeAndExpiry() throws {
        let reminder = CompanionReminder(promptID: UUID(), title: "Move", subtitle: "Explore", body: "Three choices",
            dueAt: now.addingTimeInterval(300), expiresAt: now.addingTimeInterval(900))
        let packet = CompanionPacket(createdAt: now, payload: .reminder(reminder))
        let decoded = try JSONDecoder().decode(CompanionPacket.self, from: JSONEncoder().encode(packet))
        guard case .reminder(let copy) = decoded.payload else { return XCTFail("Expected reminder") }
        XCTAssertEqual(copy.promptID, reminder.promptID)
        XCTAssertEqual(copy.dueAt, reminder.dueAt)
        XCTAssertEqual(copy.expiresAt, reminder.expiresAt)
        XCTAssertEqual(decoded.id, packet.id)
    }

    func testLatePhoneTransferDoesNotCreateAnotherWatchAlert() {
        let reminder = CompanionReminder(promptID: UUID(), title: "Move", subtitle: "", body: "",
            dueAt: now, expiresAt: now.addingTimeInterval(600))
        XCTAssertTrue(MovementNotification.canRelay(reminder, at: now))
        XCTAssertTrue(MovementNotification.canRelay(reminder, at: now.addingTimeInterval(10)))
        XCTAssertFalse(MovementNotification.canRelay(reminder, at: now.addingTimeInterval(11)))
        XCTAssertFalse(MovementNotification.canRelay(reminder, at: now.addingTimeInterval(600)))
        XCTAssertEqual(MovementNotification.requestID(reminder.promptID), reminder.promptID.uuidString)
    }

    func testPhoneCanScheduleAFutureWatchSnoozeWithoutTreatingItAsLate() {
        let reminder = CompanionReminder(promptID: UUID(), title: "Move", subtitle: "", body: "",
            dueAt: now.addingTimeInterval(300), expiresAt: now.addingTimeInterval(900))
        XCTAssertTrue(MovementNotification.canRelay(reminder, at: now))
        XCTAssertTrue(MovementNotification.canRelay(reminder, at: now.addingTimeInterval(305)))
        XCTAssertFalse(MovementNotification.canRelay(reminder, at: now.addingTimeInterval(311)))
    }

    func testPhoneSnoozeRejectsExpiredDelayedAndUnsupportedActions() throws {
        let id = UUID()
        let request = CompanionSnooze(promptID: id, minutes: 5, expiresAt: now.addingTimeInterval(600))
        XCTAssertTrue(request.isValid(requestedAt: now, now: now.addingTimeInterval(1)))
        XCTAssertFalse(request.isValid(requestedAt: now, now: now.addingTimeInterval(61)))
        XCTAssertFalse(request.isValid(requestedAt: now.addingTimeInterval(5), now: now))
        XCTAssertFalse(CompanionSnooze(promptID: id, minutes: 3, expiresAt: now.addingTimeInterval(600)).isValid(requestedAt: now, now: now))
        XCTAssertFalse(CompanionSnooze(promptID: id, minutes: 10, expiresAt: now).isValid(requestedAt: now, now: now))
        let packet = CompanionPacket(createdAt: now, payload: .snooze(request))
        let decoded = try JSONDecoder().decode(CompanionPacket.self, from: JSONEncoder().encode(packet))
        guard case .snooze(let copy) = decoded.payload else { return XCTFail("Expected snooze action") }
        XCTAssertEqual(copy.promptID, id)
        XCTAssertEqual(copy.minutes, 5)
        XCTAssertEqual(copy.expiresAt, request.expiresAt)
    }

}
