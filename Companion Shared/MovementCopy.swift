import Foundation

// Shared screen copy keeps the phone and watch speaking the same language.
nonisolated enum MovementCopy {
    static let completionNote = "Completed breaks are the ones you marked ‘I did it’."
    static let privacy = "Your activity stays on your paired devices until you choose to share it. No account is needed."
    static let shareNote = "Your files include your activity, health readings, and break history. Share them only with someone you trust."
    static let reminderTiming = "Choose how long to wait after little movement, the gap between reminders, and the hours that suit you."
    static let calendarNote = "Reminders wait while your selected calendars say you’re busy."
    static let suggestionNote = "Your choices help shape future suggestions. Mix in surprise choices for more variety; familiar exercises may still appear."
    static let healthNote = "Apple keeps individual Health permissions private. If readings stay unavailable, check your Health permissions."
    static let timerIntro = "Give yourself more time before your watch returns to the clock."
    static let timerPath = "On your Watch: Settings → General → Return to Clock → ExerciseAnalyser → Custom → After 1 hour."
    static let timerNote = "Your screen can still dim, and you can leave the app whenever you like."

    static func outcome(_ value: String) -> String {
        switch value.lowercased() {
        case "prepared": "Getting ready"
        case "scheduled": "Invited"
        case "selected": "Exercise chosen"
        case "completed": "Completed"
        case "abandoned": "Ended early"
        case "dismissed": "Dismissed"
        case "expired", "ignored": "Missed"
        case "cancelled": "Cancelled"
        case "failed": "Couldn’t send reminder"
        default: value
        }
    }

    static func settingTitle(_ value: String) -> String {
        switch value {
        case "Active hours": "Reminder hours"
        case "Low movement", "Inactivity": "After little movement"
        case "Reminder cooldown", "Cooldown": "Time between reminders"
        case "Daily reminder limit", "Daily limit": "Daily limit"
        case "Exploration": "Surprise choices"
        case "Enabled exercises": "Your exercises"
        default: value
        }
    }

    static func permissionValue(_ value: String) -> String {
        switch value {
        case "Configured; read access is private", "Authorization flow completed": "Setup complete"
        case "Full access", "Authorized": "Allowed"
        case "Needs access on watch": "Allow on your Watch"
        default: value
        }
    }

    static func eventTitle(_ kind: String) -> String {
        switch kind {
        case "opportunity_evaluated": "Checked for a good moment"
        case "check_started": "Looking for a good moment"
        case "notification_scheduled": "Reminder requested"
        case "notification_snoozed": "Reminder delayed"
        case "companion_snooze_received": "Reminder delay requested"
        case "notification_failed", "notification_snooze_failed": "Couldn’t send a reminder"
        case "exercise_completed": "Break completed"
        case "exercise_started": "Break started"
        case "session_started": "Watch app session started"
        case "exercise_paused": "Break paused"
        case "exercise_abandoned": "Break ended early"
        case "exercise_timer_ended": "Timer finished"
        case "exercise_movement_assessed": "Movement checked"
        case "ignored_break": "Break left unfinished"
        case "opened": "Invitation opened"
        case "foreground_received": "Reminder received while the app was open"
        case "manual_intervention": "You asked for a break"
        case "settings_changed": "Settings updated"
        case "export_prepared", "companion_export_prepared": "Your files are ready"
        case "health_observer_received": "Health update received"
        case "permission_requested": "Permission requested"
        case "permission_result": "Permissions checked"
        case "background_refresh_started", "background_refresh_completed": "Watch refreshed in the background"
        case "foreground_entered": "App opened"
        case "background_entered": "App moved to the background"
        default: "Watch activity updated"
        }
    }
}
