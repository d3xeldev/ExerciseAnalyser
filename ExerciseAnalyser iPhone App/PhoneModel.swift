import Foundation
import Observation
import UIKit
import UserNotifications

@MainActor
@Observable
final class PhoneModel {
    static let shared = PhoneModel()
    private(set) var snapshot: CompanionSnapshot?
    private(set) var previewingAlert = false
    private(set) var connectionStatus = "Connecting to Apple Watch…"
    private(set) var notificationStatus = "Not checked"
    private(set) var soundStatus = "Not checked"
    private(set) var notificationActivity = "No reminder activity yet."
    private(set) var exportStatus = "Prepare a copy of your data from your Watch."
    private(set) var exportURLs: [URL] = []
    var openedPromptID: UUID?
    var error: String?
    @ObservationIgnored lazy var notifications = PhoneNotifications()
    @ObservationIgnored private let connection = CompanionConnection.shared
    @ObservationIgnored private var latestExportBatch: String?

    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Companion")
    }

    let isPreview: Bool

    private init(isPreview: Bool = ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1") {
        self.isPreview = isPreview
        if isPreview { return }
        UserDefaults.standard.register(defaults: ["phone.reminders": true, "phone.sound": true, "phone.haptics": true])
        if let data = try? Data(contentsOf: directory.appendingPathComponent("snapshot.json")),
           let cached = try? JSONDecoder().decode(CompanionSnapshot.self, from: data), cached.schemaVersion == 1 {
            snapshot = cached
        }
        if let saved = UserDefaults.standard.dictionary(forKey: "phone.latestExport") as? [String: String],
           let participant = saved["participant"], UUID(uuidString: participant) != nil,
           let batch = saved["batch"], UUID(uuidString: batch) != nil {
            let folder = directory.appendingPathComponent("Exports/\(participant)/\(batch)")
            let names = ["exercise-study.json", "exercise-choices.csv", "exercise-events.jsonl"]
            var files = names.map { folder.appendingPathComponent($0) }
            let audit = folder.appendingPathComponent("phone-notification-events.jsonl")
            if FileManager.default.fileExists(atPath: audit.path) { files.append(audit) }
            if files.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) {
                exportURLs = files
                latestExportBatch = batch
                exportStatus = "Your last files are ready to share · \(saved["received"] ?? "previous session")"
            }
        }
        notifications.onOpen = { [weak self] in self?.openedPromptID = $0 }
        notifications.onSnooze = { [weak self] snooze in self?.connection.send(.snooze(snooze)) }
        notifications.onActivity = { [weak self] in self?.recordNotification($0) }
        connection.onSnapshot = { [weak self] in self?.receiveSnapshot($0) }
        connection.onStatus = { [weak self] in self?.connectionStatus = $0 }
        connection.onError = { [weak self] in self?.error = $0 }
        connection.onFile = { [weak self] in self?.receiveExport($0, metadata: $1) }
        connection.onPacket = { [weak self] packet in
            guard let self else { return }
            do {
                switch packet.payload {
                case .reminder(let reminder): try await self.notifications.receive(reminder, version: packet.createdAt)
                case .cancel(let ids): self.notifications.cancel(ids, version: packet.createdAt)
                case .exportError(let message): self.exportStatus = "Export failed: \(message)"
                default: break
                }
            } catch {
                self.error = "Phone reminder failed: \(error.localizedDescription)"
                if case .reminder(let reminder) = packet.payload {
                    self.recordNotification(.init(kind: "request_failed", promptID: reminder.promptID, detail: error.localizedDescription))
                }
            }
        }
        connection.start()
    }

    func foreground() async {
        guard !isPreview else { return }
        await refreshPermissions()
    }

    func refreshPermissions() async {
        guard !isPreview else { return }
        let settings = await notifications.settings()
        notificationStatus = switch settings.authorizationStatus {
        case .notDetermined: "Not set up"
        case .denied: "Off — enable in Settings"
        case .authorized: settings.alertSetting == .enabled ? "On" : "Off in Settings"
        case .provisional: "Quiet delivery"
        case .ephemeral: "Temporary access"
        @unknown default: "Unknown"
        }
        soundStatus = settings.soundSetting == .enabled ? "On" : "Disabled in Settings"
    }

    func requestNotifications() async {
        guard !isPreview else { return }
        do { try await notifications.requestAccess(); await refreshPermissions() }
        catch { self.error = error.localizedDescription }
    }

    func refresh() { if !isPreview { connection.send(.requestSnapshot) } }

    func requestExport() {
        guard !isPreview else { return }
        exportStatus = "Getting your files from your Watch. Keep your devices nearby."
        connection.send(.requestExport)
    }

    func previewAlert() {
        guard !isPreview else { return }
        guard !previewingAlert else { return }
        previewingAlert = true
        Task {
            defer { previewingAlert = false }
            do { try await notifications.preview() }
            catch { self.error = "Could not play the preview: \(error.localizedDescription)" }
        }
    }

    func openSettings() {
        guard !isPreview else { return }
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    private func recordNotification(_ event: PhoneNotificationEvent) {
        notificationActivity = "\(event.date.formatted(date: .abbreviated, time: .shortened)): \(event.detail)"
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = directory.appendingPathComponent("phone-notification-events.jsonl")
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var data = try encoder.encode(event)
            data.append(10)
            if !FileManager.default.fileExists(atPath: url.path) {
                try Data().write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch { self.error = "Could not save phone notification activity: \(error.localizedDescription)" }
    }

    private func receiveSnapshot(_ data: Data) {
        do {
            let incoming = try JSONDecoder().decode(CompanionSnapshot.self, from: data)
            guard incoming.schemaVersion == 1 else { throw CocoaError(.coderReadCorrupt) }
            guard snapshot.map({ incoming.generatedAt > $0.generatedAt }) ?? true else { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent("snapshot.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            snapshot = incoming
        } catch { self.error = "Could not save the watch summary: \(error.localizedDescription)" }
    }

    private func receiveExport(_ url: URL, metadata: [String: String]) {
        defer { try? FileManager.default.removeItem(at: url) }
        let names = ["exercise-study.json", "exercise-choices.csv", "exercise-events.jsonl"]
        guard let batch = metadata["batch"], UUID(uuidString: batch) != nil,
              let name = metadata["name"], names.contains(name),
              let participant = metadata["participantID"], UUID(uuidString: participant) != nil else {
            error = "Received an unrecognized study export."
            return
        }
        do {
            let destination = directory.appendingPathComponent("Exports/\(participant)/\(batch)")
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let file = destination.appendingPathComponent(name)
            let data = try Data(contentsOf: url)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let files = names.map { destination.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
            if files.count == names.count {
                var completeFiles = files
                let audit = directory.appendingPathComponent("phone-notification-events.jsonl")
                if FileManager.default.fileExists(atPath: audit.path) {
                    let auditCopy = destination.appendingPathComponent(audit.lastPathComponent)
                    try Data(contentsOf: audit).write(to: auditCopy, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    completeFiles.append(auditCopy)
                }
                exportURLs = completeFiles
                latestExportBatch = batch
                let received = Date().formatted(date: .abbreviated, time: .shortened)
                exportStatus = "Your files are ready to share · \(received)"
                UserDefaults.standard.set(["participant": participant, "batch": batch, "received": received], forKey: "phone.latestExport")
            } else if latestExportBatch != batch {
                exportStatus = "Getting your files (\(files.count) of 3)…"
            }
        } catch { self.error = "Could not save the research export: \(error.localizedDescription)" }
    }
}

#if DEBUG
extension PhoneModel {
    static func preview(snapshot: CompanionSnapshot? = nil) -> PhoneModel {
        let model = PhoneModel(isPreview: true)
        model.snapshot = snapshot
        model.connectionStatus = snapshot == nil ? "Waiting for Apple Watch" : "Apple Watch connected"
        model.notificationStatus = snapshot == nil ? "Not set up" : "On"
        model.soundStatus = snapshot == nil ? "Not checked" : "On"
        return model
    }

    // Relative dates keep Today and active invitations useful whenever the canvas opens.
    static func previewSnapshot(stale: Bool = false, missingSignals: Bool = false, emptyDay: Bool = false, selectedEffort: String = "easy") -> CompanionSnapshot {
        let now = Date()
        let checked = stale ? now.addingTimeInterval(-86400) : now
        let options: [CompanionSnapshot.Option] = [
            .init(id: "shoulders", title: "Shoulder reset", effort: "Low", minutes: 1, symbol: "figure.flexibility", instructions: "Slowly roll your shoulders, then gently reach overhead. Keep the movement comfortable."),
            .init(id: "walk", title: "Walking break", effort: "Moderate", minutes: 3, symbol: "figure.walk", instructions: "Take a steady walk at a comfortable pace. Choose a clear route and ease off whenever you need."),
            .init(id: "brisk", title: "Brisk walk", effort: "High", minutes: 5, symbol: "figure.walk", instructions: "Walk a little faster than usual on a safe, level route. Keep a pace where you can still speak comfortably.")
        ]
        return CompanionSnapshot(
            generatedAt: checked, participantID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            dataAvailable: true, monitoring: !missingSignals, checkedAt: checked, status: "Space for a movement break",
            steps: missingSignals ? nil : 6248, heartRate: missingSignals ? nil : 72,
            heartRateAt: missingSignals ? nil : checked, exerciseMinutes: missingSignals ? nil : 24,
            sleepHours: missingSignals ? nil : 7.4,
            days: (-6...0).map { offset in
                .init(date: Calendar.current.date(byAdding: .day, value: offset, to: checked)!,
                      steps: missingSignals || offset == -3 ? nil : Double(6248 + offset * 570),
                      low: missingSignals || emptyDay ? 0 : (offset + 7) % 3, moderate: missingSignals || emptyDay ? 0 : 1,
                      high: missingSignals || emptyDay ? 0 : (offset + 6) % 2, missed: emptyDay ? 0 : (offset + 8) % 3,
                      selections: .init(low: emptyDay ? 0 : (selectedEffort == "easy" ? 3 : 1),
                                        moderate: emptyDay ? 0 : (selectedEffort == "moderate" ? 3 : 1),
                                        high: emptyDay ? 0 : (selectedEffort == "challenge" ? 3 : 1)))
            },
            prompts: [
                .init(id: UUID(), date: now.addingTimeInterval(-120), outcome: "Scheduled", method: "Personalized", isManual: false,
                      options: options, selectedTitle: nil, expiresAt: now.addingTimeInterval(600)),
                .init(id: UUID(), date: now.addingTimeInterval(-7200), outcome: "Completed", method: "Discover your favorites", isManual: true,
                      options: options, selectedTitle: "Walking break", expiresAt: now.addingTimeInterval(-6600))
            ],
            events: [
                .init(id: UUID(), date: now.addingTimeInterval(-120), kind: "notification_scheduled", source: "planner"),
                .init(id: UUID(), date: now.addingTimeInterval(-7200), kind: "exercise_completed", source: "app")
            ],
            permissions: [.init(title: "Health", value: "Authorization flow completed"), .init(title: "Calendar", value: "Full access"),
                          .init(title: "Motion", value: "Authorized"), .init(title: "Notifications", value: "Enabled")],
            preferences: [.init(title: "Active hours", value: "09:00–21:00"), .init(title: "Inactivity", value: "30 minutes"),
                          .init(title: "Cooldown", value: "60 minutes"), .init(title: "Daily limit", value: "6")],
            issues: missingSignals ? ["Health readings unavailable. Missing data is not zero."] : [],
            totalPrompts: 32, requestedNotifications: 28, completedBreaks: 19
        )
    }
}
#endif
