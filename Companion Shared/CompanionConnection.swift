import Foundation
import WatchConnectivity

@MainActor
final class CompanionConnection: NSObject, WCSessionDelegate {
    static let shared = CompanionConnection()
    var onPacket: ((CompanionPacket) async -> Void)?
    var onSnapshot: ((Data) -> Void)?
    var onFile: ((URL, [String: String]) -> Void)?
    var onStatus: ((String) -> Void)?
    var onError: ((String) -> Void)?
    var onActivated: (() -> Void)?
    private var processing: Task<Void, Never>?
    private var latestSnapshot: Data?
    private let session = WCSession.isSupported() ? WCSession.default : nil
    private let outboxKey = "companion.outbox.v1"

    func start() {
        guard let session else { onStatus?("Watch connection unavailable"); return }
        session.delegate = self
        session.activate()
    }

    func publish(_ snapshot: CompanionSnapshot) {
        do {
            latestSnapshot = try JSONEncoder().encode(snapshot)
            flushSnapshot()
        } catch { onError?(error.localizedDescription) }
    }

    private func flushSnapshot() {
        guard let session, session.activationState == .activated, let latestSnapshot else { return }
        do { try session.updateApplicationContext(["snapshot": latestSnapshot]) }
        catch { onError?("Snapshot sync: \(error.localizedDescription)") }
    }

    func send(_ payload: CompanionPacket.Payload) {
        do {
            let data = try JSONEncoder().encode(CompanionPacket(payload: payload))
            var outbox = UserDefaults.standard.array(forKey: outboxKey) as? [Data] ?? []
            outbox.append(data)
            UserDefaults.standard.set(outbox, forKey: outboxKey)
            flushOutbox()
        } catch { onError?(error.localizedDescription) }
    }

    private func flushOutbox() {
        guard let session, session.activationState == .activated else { return }
        let outbox = UserDefaults.standard.array(forKey: outboxKey) as? [Data] ?? []
        for data in outbox {
            guard let packet = try? JSONDecoder().decode(CompanionPacket.self, from: data),
                  Date().timeIntervalSince(packet.createdAt) < 24 * 60 * 60 else { continue }
            let message: [String: Any] = ["packet": data]
            // The OS retains the durable transfer if the immediate path cannot reach the other device.
            session.transferUserInfo(message)
            if session.isReachable { session.sendMessage(message, replyHandler: nil, errorHandler: { _ in }) }
        }
        UserDefaults.standard.removeObject(forKey: outboxKey)
    }

    func transferFile(_ url: URL, metadata: [String: String]) {
        guard let session, session.activationState == .activated else {
            onError?("Watch connection is not ready. Try the export again.")
            return
        }
        session.transferFile(url, metadata: metadata)
    }

    private func updateStatus() {
        guard let session else { return }
        #if os(iOS)
        if !session.isPaired { onStatus?("Pair an Apple Watch to get started"); return }
        if !session.isWatchAppInstalled { onStatus?("Install Move Moment on your watch"); return }
        #endif
        onStatus?(session.isReachable ? "Watch and iPhone connected" : "Waiting for the next connection")
    }

    func finishPendingWork() async { await processing?.value }

    private func receive(_ data: Data) {
        guard let packet = try? JSONDecoder().decode(CompanionPacket.self, from: data), packet.schemaVersion == 1 else {
            onError?("Update both apps to read this companion message.")
            return
        }
        let previous = processing
        processing = Task { @MainActor [weak self] in
            await previous?.value
            await self?.onPacket?(packet)
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let snapshot = session.receivedApplicationContext["snapshot"] as? Data
        let errorDescription = error?.localizedDescription
        Task { @MainActor in
            if let errorDescription { self.onError?(errorDescription) }
            self.updateStatus()
            guard activationState == .activated else { return }
            if let snapshot { self.onSnapshot?(snapshot) }
            self.flushOutbox()
            self.flushSnapshot()
            self.onActivated?()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.updateStatus()
            self.flushOutbox()
            self.flushSnapshot()
        }
    }

    nonisolated func session(_ session: WCSession, didFinish userInfoTransfer: WCSessionUserInfoTransfer, error: Error?) {
        guard let error else { return }
        let description = error.localizedDescription
        let data = userInfoTransfer.userInfo["packet"] as? Data
        Task { @MainActor in
            if let data {
                var outbox = UserDefaults.standard.array(forKey: self.outboxKey) as? [Data] ?? []
                if !outbox.contains(data) { outbox.append(data) }
                UserDefaults.standard.set(outbox, forKey: self.outboxKey)
            }
            self.onError?("Companion transfer will retry on the next connection: \(description)")
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let data = message["packet"] as? Data else { return }
        Task { @MainActor in self.receive(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard let data = userInfo["packet"] as? Data else { return }
        Task { @MainActor in self.receive(data) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext["snapshot"] as? Data else { return }
        Task { @MainActor in self.onSnapshot?(data) }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // WCSession removes the incoming file when this callback returns; copy synchronously first.
        do {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: file.fileURL, to: copy)
            let metadata = file.metadata as? [String: String] ?? [:]
            Task { @MainActor in self.onFile?(copy, metadata) }
        } catch {
            let description = error.localizedDescription
            Task { @MainActor in self.onError?("Export receive failed: \(description)") }
        }
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: Error?) {
        if let error {
            let description = error.localizedDescription
            Task { @MainActor in
                self.onError?("Export transfer failed: \(description)")
                self.send(.exportError(description))
            }
        } else {
            // Each export has its own immutable directory, so queued transfers cannot read a newer export.
            try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        }
    }

    #if os(iOS)
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.updateStatus() }
    }
    #endif
}
