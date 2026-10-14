import CoreMotion
import Foundation

@MainActor
final class ExerciseEvidenceService {
    private let motion = CMMotionManager()
    private let pedometer = CMPedometer()
    private var observed: Set<Int> = []
    private var moving: Set<Int> = []
    private var previous: CMAcceleration?
    private var collectionID = UUID()

    func start(until deadline: Date) {
        guard !motion.isAccelerometerActive else { return }
        observed = []
        moving = []
        previous = nil
        collectionID = UUID()
        let id = collectionID
        guard motion.isAccelerometerAvailable,
              CMMotionActivityManager.authorizationStatus() == .authorized else { return }
        motion.accelerometerUpdateInterval = 0.1
        motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
            Task { @MainActor in
                guard let self, self.collectionID == id, let data, Date() <= deadline else { return }
                let second = Int(data.timestamp)
                self.observed.insert(second)
                let acceleration = data.acceleration
                if let previous = self.previous {
                    let delta = sqrt(pow(acceleration.x - previous.x, 2) + pow(acceleration.y - previous.y, 2) + pow(acceleration.z - previous.z, 2))
                    if delta > 0.08 { self.moving.insert(second) }
                }
                self.previous = acceleration
            }
        }
    }

    func stop() -> (movement: Double, observed: Double) {
        motion.stopAccelerometerUpdates()
        collectionID = UUID()
        let result = (Double(moving.count), Double(observed.count))
        moving = []
        observed = []
        previous = nil
        return result
    }

    func evidence(for session: ExerciseSession) async -> ExerciseEvidence {
        var evidence = ExerciseEvidence(wristMovementSeconds: session.wristMovementSeconds, wristObservedSeconds: session.wristObservedSeconds)
        guard CMPedometer.isStepCountingAvailable(), CMPedometer.authorizationStatus() == .authorized else { return evidence }
        var steps = 0.0
        var distance = 0.0
        var hasDistance = false
        // Query only running intervals so activity during pauses never counts.
        for interval in session.intervals where interval.duration > 0 {
            let result = await query(interval)
            guard let result else { return evidence }
            steps += result.numberOfSteps.doubleValue
            if let meters = result.distance { distance += meters.doubleValue; hasDistance = true }
        }
        evidence.steps = steps
        evidence.distanceMeters = hasDistance ? distance : nil
        return evidence
    }

    private func query(_ interval: DateInterval) async -> CMPedometerData? {
        let ticket = PedometerTicket()
        return await withCheckedContinuation { continuation in
            ticket.continuation = continuation
            pedometer.queryPedometerData(from: interval.start, to: interval.end) { data, error in
                Task { @MainActor in ticket.finish(error == nil ? data : nil) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(4))
                ticket.finish(nil)
            }
        }
    }
}

@MainActor
private final class PedometerTicket {
    var continuation: CheckedContinuation<CMPedometerData?, Never>?

    func finish(_ value: CMPedometerData?) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}
