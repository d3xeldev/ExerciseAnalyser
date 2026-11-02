import UserNotifications

// Register the same actions on the originating phone and on the watch: iOS may forward either alert.
@MainActor
enum MovementNotificationCategory {
    static func make(identifier: String = MovementNotification.categoryID) -> UNNotificationCategory {
        UNNotificationCategory(identifier: identifier, actions: [
            UNNotificationAction(identifier: MovementNotification.choose, title: "Choose exercise", options: [.foreground]),
            UNNotificationAction(identifier: MovementNotification.snoozeFive, title: "In 5 minutes", options: []),
            UNNotificationAction(identifier: MovementNotification.snoozeTen, title: "In 10 minutes", options: [])
        ], intentIdentifiers: [], options: [.customDismissAction])
    }
}
