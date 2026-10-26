import UserNotifications
import UIKit

@MainActor
final class PhoneNotifications: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    private var ledger: CompanionReminderLedger
    private let feedback = PhoneFeedback()
    var onOpen: ((UUID) -> Void)?
    var onSnooze: ((CompanionSnooze) -> Void)?
    var onActivity: ((PhoneNotificationEvent) -> Void)?

    override init() {
        ledger = UserDefaults.standard.data(forKey: "phone.reminderLedger").flatMap {
            try? JSONDecoder().decode(CompanionReminderLedger.self, from: $0)
        } ?? CompanionReminderLedger()
        super.init()
        center.delegate = self
        center.setNotificationCategories([MovementNotificationCategory.make()])
        Task { await removeLegacyRequests() }
    }

    func settings() async -> UNNotificationSettings { await center.notificationSettings() }

    func requestAccess() async throws {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
    }

    func receive(_ reminder: CompanionReminder, version: Date) async throws {
        await removeLegacyRequests()
        let now = Date()
        guard ledger.accepts(id: reminder.promptID, version: version, expiresAt: reminder.expiresAt, now: now) else { return }
        guard UserDefaults.standard.bool(forKey: "phone.reminders") else {
            onActivity?(.init(kind: "disabled", promptID: reminder.promptID, detail: "Phone reminder preference is off."))
            record(reminder.promptID, version: version)
            return
        }
        let settings = await settings()
        guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else {
            onActivity?(.init(kind: "permission_disabled", promptID: reminder.promptID, detail: "Phone alert skipped: notification permission is off."))
            record(reminder.promptID, version: version)
            return
        }
        guard MovementNotification.canRelay(reminder, at: Date()) else {
            record(reminder.promptID, version: version)
            onActivity?(.init(kind: "late_relay_skipped", promptID: reminder.promptID, detail: "Late phone transfer suppressed to avoid repeating the watch alert."))
            return
        }
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.subtitle = reminder.subtitle
        content.body = reminder.body
        content.threadIdentifier = "movement"
        content.categoryIdentifier = MovementNotification.categoryID
        if UserDefaults.standard.bool(forKey: "phone.sound") {
            content.sound = UNNotificationSound(named: UNNotificationSoundName("movement-chime.wav"))
        }
        content.userInfo = ["promptID": reminder.promptID.uuidString, "expiresAt": reminder.expiresAt.timeIntervalSince1970]
        let identifier = MovementNotification.requestID(reminder.promptID)
        // Replace a prior immediate or snoozed version of this invitation.
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        let delay = reminder.dueAt.timeIntervalSinceNow
        let trigger = delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false) : nil
        try await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
        record(reminder.promptID, version: version)
        onActivity?(.init(kind: "request_accepted", promptID: reminder.promptID, detail: "Phone notification requested. Delivery is controlled by iOS."))
    }

    func cancel(_ ids: [UUID], version: Date) {
        let now = Date()
        for id in ids where ledger.accepts(id: id, version: version, expiresAt: now.addingTimeInterval(1), now: now) {
            let identifier = MovementNotification.requestID(id)
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            center.removeDeliveredNotifications(withIdentifiers: [identifier])
            record(id, version: version)
            onActivity?(.init(kind: "cancelled", promptID: id, detail: "Phone request removed after a watch update."))
        }
    }

    private func removeLegacyRequests() async {
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        let identifiers = Set(pending.map(\.identifier) + delivered.map { $0.request.identifier })
            .filter { $0.hasPrefix("movement.") }
        // Older builds used a different request ID and had no actions on the forwarded phone alert.
        center.removePendingNotificationRequests(withIdentifiers: Array(identifiers))
        center.removeDeliveredNotifications(withIdentifiers: Array(identifiers))
    }

    func disableReminders() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    private func record(_ id: UUID, version: Date) {
        ledger.record(id: id, version: version, now: Date())
        if let data = try? JSONEncoder().encode(ledger) { UserDefaults.standard.set(data, forKey: "phone.reminderLedger") }
    }

    func preview() async throws {
        guard UIApplication.shared.applicationState == .active else { return }
        let url = UserDefaults.standard.bool(forKey: "phone.sound")
            ? Bundle.main.url(forResource: "movement-chime", withExtension: "wav") : nil
        async let chime: Void = feedback.playChime(at: url)
        await playHaptic()
        try await chime
    }

    private func playHaptic() async {
        guard UserDefaults.standard.bool(forKey: "phone.haptics"), UIApplication.shared.applicationState == .active else { return }
        do { try await feedback.playHaptic() }
        catch {
            if UIApplication.shared.applicationState == .active {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let expiresAt = notification.request.content.userInfo["expiresAt"] as? Double ?? 0
        guard expiresAt > Date().timeIntervalSince1970 else { completionHandler([]); return }
        Task { @MainActor in
            guard UserDefaults.standard.bool(forKey: "phone.reminders") else { completionHandler([]); return }
            Task { await self.playHaptic() }
            let id = (notification.request.content.userInfo["promptID"] as? String).flatMap(UUID.init(uuidString:))
            self.onActivity?(.init(kind: "foreground_received", promptID: id, detail: "Phone received a reminder while open."))
            completionHandler(UserDefaults.standard.bool(forKey: "phone.sound") ? [.banner, .list, .sound] : [.banner, .list])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let id = (info["promptID"] as? String).flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier
        let expiry = (info["expiresAt"] as? Double).map(Date.init(timeIntervalSince1970:))
        Task { @MainActor in
            defer { completionHandler() }
            guard let id else { return }
            switch action {
            case MovementNotification.snoozeFive, MovementNotification.snoozeTen:
                guard let expiry, expiry > Date() else { return }
                let minutes = action == MovementNotification.snoozeFive ? 5 : 10
                self.onActivity?(.init(kind: "snooze_requested", promptID: id, detail: "Requested a \(minutes)-minute delay on the watch."))
                self.onSnooze?(.init(promptID: id, minutes: minutes, expiresAt: expiry))
            case UNNotificationDefaultActionIdentifier, MovementNotification.choose:
                self.onActivity?(.init(kind: "opened", promptID: id, detail: "Participant opened the phone reminder; this is not an exercise selection."))
                self.onOpen?(id)
            case UNNotificationDismissActionIdentifier:
                self.onActivity?(.init(kind: "dismissed", promptID: id, detail: "Phone notification dismissed; watch exercise state is unchanged."))
            default: break
            }
        }
    }
}

nonisolated struct PhoneNotificationEvent: Codable {
    var date = Date()
    let kind: String
    let promptID: UUID?
    let detail: String
}
