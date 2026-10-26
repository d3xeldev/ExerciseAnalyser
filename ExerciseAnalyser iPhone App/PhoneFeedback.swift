import AVFAudio
import CoreHaptics

// Media objects stay on this actor, away from the UI and notification delegate's main actor.
actor PhoneFeedback {
    private var hapticEngine: CHHapticEngine?
    private var startingHaptics = false

    func playChime(at url: URL?) async throws {
        guard let url else { return }
        let player = try AVAudioPlayer(contentsOf: url)
        let session = AVAudioSession.sharedInstance()
        // Respect silent mode and leave other apps' audio playing during the preview.
        try session.setCategory(.ambient)
        do {
            guard try await session.activate() else {
                throw NSError(domain: "MoveMoment.Feedback", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "The audio session could not be activated."])
            }
            guard player.play() else {
                throw NSError(domain: "MoveMoment.Feedback", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "The movement chime could not be played."])
            }
            try await Task.sleep(for: .seconds(player.duration + 0.1))
        } catch {
            player.stop()
            _ = try? await session.deactivate(options: [.notifyOthersOnDeactivation])
            throw error
        }
        player.stop()
        _ = try await session.deactivate(options: [.notifyOthersOnDeactivation])
    }

    func playHaptic() async throws {
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics, !startingHaptics else { return }
        startingHaptics = true
        defer { startingHaptics = false }
        if hapticEngine == nil {
            let engine = try CHHapticEngine()
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = true
            hapticEngine = engine
        }
        guard let engine = hapticEngine else { return }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                engine.start { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
            let events = [0.0, 0.16, 0.38].map { time in
                CHHapticEvent(eventType: .hapticTransient, parameters: [
                    .init(parameterID: .hapticIntensity, value: 0.7),
                    .init(parameterID: .hapticSharpness, value: 0.45)
                ], relativeTime: time)
            }
            let pattern = try CHHapticPattern(events: events, parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            hapticEngine = nil
            throw error
        }
    }
}
