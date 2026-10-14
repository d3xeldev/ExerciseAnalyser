import UserNotifications

@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()
    var onResponse: ((UUID, String, Date) async -> Void)?
    var onForeground: ((UUID) -> Void)?

    override init() {
        super.init()
        center.delegate = self
    }

    func requestAccess() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound])
    }

    func isAuthorized() async -> Bool {
        let settings = await center.notificationSettings()
        return [.authorized, .provisional].contains(settings.authorizationStatus) && settings.alertSetting == .enabled
    }

    func registerCategories(for prompts: [ExercisePrompt]) {
        let categories = prompts.suffix(64).map { prompt in
            let actions = prompt.options.map { option in
                UNNotificationAction(identifier: option.id,
                                     title: "\(option.exercise.effort.title): \(option.exercise.title) · \(option.exercise.minutes)m",
                                     options: [.foreground])
            }
            return UNNotificationCategory(identifier: "movement.\(prompt.id.uuidString)", actions: actions,
                                          intentIdentifiers: [], options: [.customDismissAction])
        }
        center.setNotificationCategories(Set(categories))
    }

    func schedule(_ prompt: ExercisePrompt) async throws {
        let content = UNMutableNotificationContent()
        content.title = prompt.plannedFor == nil ? "A little time to move" : "Time for a movement break?"
        content.subtitle = prompt.method.title
        content.body = prompt.options.map { "\($0.exercise.effort.title): \($0.exercise.title) (\($0.exercise.minutes) min)" }.joined(separator: "\n")
        content.sound = .default
        content.categoryIdentifier = "movement.\(prompt.id.uuidString)"
        content.threadIdentifier = "movement"
        content.userInfo = ["promptID": prompt.id.uuidString]
        guard prompt.plannedFor == nil else {
            throw NSError(domain: "Notifications", code: 1, userInfo: [NSLocalizedDescriptionKey: "Future reminders require a fresh opportunity check."])
        }
        // This final synchronous check also covers an event starting while health queries were running.
        let now = Date()
        let context = CalendarService().populate(.init(date: now, localHour: Calendar.current.component(.hour, from: now)))
        guard context.calendarAvailable, !context.busy,
              ReminderPlanning.freeMinutes(at: now, context: context, settings: prompt.settings) >= Double((prompt.options.map { $0.exercise.minutes }.max() ?? 5) + 2) else {
            throw NSError(domain: "Notifications", code: 2, userInfo: [NSLocalizedDescriptionKey: "Calendar no longer has a free movement window."])
        }
        try await center.add(UNNotificationRequest(identifier: prompt.id.uuidString, content: content, trigger: nil))
    }

    func scheduleExerciseEnd(promptID: UUID, exercise: Exercise, at date: Date) async throws {
        let content = UNMutableNotificationContent()
        content.title = "Time’s up. Nice work!"
        content.body = "Your \(exercise.title.lowercased()) timer is complete. Open to see your movement check."
        content.sound = .default
        content.userInfo = ["promptID": promptID.uuidString]
        try await center.add(UNNotificationRequest(identifier: "exercise-timer.\(promptID.uuidString)", content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)))
    }

    func removeExerciseEnd(_ id: UUID) {
        let identifier = "exercise-timer.\(id.uuidString)"
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }

    func remove(_ ids: [UUID]) {
        let identifiers = ids.map(\.uuidString)
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func knownRequestIDs() async -> Set<String> {
        let pending = await center.pendingNotificationRequests()
        let delivered = await center.deliveredNotifications()
        return Set(pending.map(\.identifier) + delivered.map { $0.request.identifier })
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                           withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // This delegate is called for foreground delivery; keep timer alerts for background delivery only.
        if notification.request.identifier.hasPrefix("exercise-timer.") {
            completionHandler([])
            return
        }
        let identifier = notification.request.content.userInfo["promptID"] as? String ?? notification.request.identifier
        Task { @MainActor in
            if let id = UUID(uuidString: identifier) { onForeground?(id) }
            completionHandler([.banner, .sound, .list])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                           withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let promptIdentifier = response.notification.request.content.userInfo["promptID"] as? String ?? identifier
        let action = response.actionIdentifier
        Task { @MainActor in
            defer { completionHandler() }
            if identifier.hasPrefix("exercise-timer."), action == UNNotificationDefaultActionIdentifier,
               let id = UUID(uuidString: String(identifier.dropFirst("exercise-timer.".count))) {
                await onResponse?(id, "exercise_timer", Date())
            } else if let id = UUID(uuidString: promptIdentifier) { await onResponse?(id, action, Date()) }
        }
    }
}
