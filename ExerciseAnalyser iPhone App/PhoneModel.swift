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
    private(set) var notificationActivity = "No phone reminder requests yet."
    private(set) var exportStatus = "Request the complete study files from your watch."
    private(set) var exportURLs: [URL] = []
    var openedPromptID: UUID?
    var error: String?
    @ObservationIgnored let notifications = PhoneNotifications()
    @ObservationIgnored private let connection = CompanionConnection.shared
    @ObservationIgnored private var latestExportBatch: String?

    private var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Companion")
    }

    private init() {
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
                exportStatus = "Last export: \(saved["received"] ?? "previous session"). Watch participant: \(participant)."
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
        await refreshPermissions()
    }

    func refreshPermissions() async {
        let settings = await notifications.settings()
        notificationStatus = switch settings.authorizationStatus {
        case .notDetermined: "Not requested"
        case .denied: "Off — enable in Settings"
        case .authorized: settings.alertSetting == .enabled ? "Authorized" : "Alerts disabled in Settings"
        case .provisional: "Quiet delivery"
        case .ephemeral: "Temporary access"
        @unknown default: "Unknown"
        }
        soundStatus = settings.soundSetting == .enabled ? "Allowed by iOS" : "Disabled in Settings"
    }

    func requestNotifications() async {
        do { try await notifications.requestAccess(); await refreshPermissions() }
        catch { self.error = error.localizedDescription }
    }

    func refresh() { connection.send(.requestSnapshot) }

    func requestExport() {
        exportStatus = "Requested. Keep the devices nearby; the watch will transfer three files when available."
        connection.send(.requestExport)
    }

    func previewAlert() {
        guard !previewingAlert else { return }
        previewingAlert = true
        Task {
            defer { previewingAlert = false }
            do { try await notifications.preview() }
            catch { self.error = "Could not play the preview: \(error.localizedDescription)" }
        }
    }

    func openSettings() {
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
                exportStatus = "Complete export received at \(received). Watch participant: \(participant)."
                UserDefaults.standard.set(["participant": participant, "batch": batch, "received": received], forKey: "phone.latestExport")
            } else if latestExportBatch != batch {
                exportStatus = "Receiving study files (\(files.count) of 3)…"
            }
        } catch { self.error = "Could not save the research export: \(error.localizedDescription)" }
    }
}
