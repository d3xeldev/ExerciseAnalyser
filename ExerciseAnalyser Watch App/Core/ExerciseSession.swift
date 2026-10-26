import Foundation

nonisolated struct ExerciseSession: Codable, Sendable {
    var startedAt: Date?
    var runningSince: Date?
    var intervals: [DateInterval] = []
    var endedAt: Date?
    var assessment: ExerciseAssessment?
    var wristMovementSeconds: Double = 0
    var wristObservedSeconds: Double = 0

    func elapsed(at date: Date) -> TimeInterval {
        intervals.reduce(0) { $0 + $1.duration } + (runningSince.map { max(0, date.timeIntervalSince($0)) } ?? 0)
    }

    func remaining(for exercise: Exercise, at date: Date) -> Int {
        max(0, Int(ceil(Double(exercise.minutes * 60) - elapsed(at: date))))
    }

    func deadline(for exercise: Exercise) -> Date? {
        runningSince.map { $0.addingTimeInterval(max(0, Double(exercise.minutes * 60) - intervals.reduce(0) { $0 + $1.duration })) }
    }

    mutating func start(at date: Date) {
        guard runningSince == nil, endedAt == nil else { return }
        if startedAt == nil { startedAt = date }
        runningSince = date
    }

    mutating func pause(at date: Date) {
        guard let runningSince else { return }
        intervals.append(DateInterval(start: runningSince, end: max(runningSince, date)))
        self.runningSince = nil
    }

    @discardableResult
    mutating func endIfDue(for exercise: Exercise, at date: Date) -> Bool {
        guard endedAt == nil, let deadline = deadline(for: exercise), date >= deadline else { return false }
        pause(at: deadline)
        endedAt = deadline
        return true
    }
}

nonisolated struct ExerciseEvidence: Codable, Sendable {
    var steps: Double?
    var distanceMeters: Double?
    var wristMovementSeconds: Double = 0
    var wristObservedSeconds: Double = 0
}

nonisolated struct ExerciseAssessment: Codable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case movementDetected, littleMovement, inconclusive
    }

    let outcome: Outcome
    let evidence: ExerciseEvidence
    let explanation: String
    let policyVersion: String

    static func evaluate(exercise: Exercise, evidence: ExerciseEvidence) -> Self {
        let duration = Double(exercise.minutes * 60)
        let outcome: Outcome
        let explanation: String
        switch exercise.id {
        case "stroll", "walk", "brisk":
            let stepTarget = duration * (exercise.id == "brisk" ? 0.5 : 0.3)
            if (evidence.steps ?? 0) >= stepTarget || (evidence.distanceMeters ?? 0) >= stepTarget * 0.5 {
                outcome = .movementDetected
                explanation = "Steps or walking distance matched this break."
            } else if evidence.steps != nil {
                outcome = .littleMovement
                explanation = "Only a little walking was recorded. Short walks can be missed."
            } else {
                outcome = .inconclusive
                explanation = "Walking data wasn’t available for this break."
            }
        case "ankles":
            outcome = .inconclusive
            explanation = "A watch on your wrist can’t reliably detect ankle circles."
        default:
            let movementTarget = duration * (exercise.id == "shoulders" ? 0.12 : 0.2)
            let steppingExercise = ["march", "circuit"].contains(exercise.id)
            if evidence.wristMovementSeconds >= movementTarget || (steppingExercise && (evidence.steps ?? 0) >= duration * 0.25) {
                outcome = .movementDetected
                explanation = "Movement matched this break’s gentle activity target."
            } else if evidence.wristObservedSeconds >= duration * 0.7 {
                outcome = .littleMovement
                explanation = "Only a little wrist movement was recorded. Gentle movements can be missed."
            } else {
                outcome = .inconclusive
                explanation = "There wasn’t enough sensor coverage to check this break."
            }
        }
        return .init(outcome: outcome, evidence: evidence, explanation: explanation, policyVersion: "movement-check-1")
    }
}

extension Exercise {
    var measurementHint: String {
        switch id {
        case "stroll", "walk", "brisk": "Checks steps and walking distance during the timer."
        case "ankles": "Ankle movement is hard to detect from your wrist. You can confirm it yourself."
        case "march", "circuit": "Checks steps and wrist movement during the timer."
        default: "Checks wrist movement during the timer."
        }
    }
}

// Reserve ten minutes for an unfinished break before treating it as ignored.
extension ExercisePrompt {
    var activeUntil: Date {
        let exercise = options.first { $0.id == selectedExerciseID }?.exercise
        let session = exerciseSession
        let lastActivity = session?.endedAt
            ?? exercise.flatMap { session?.deadline(for: $0) }
            ?? session?.intervals.last?.end
            ?? session?.startedAt
            ?? respondedAt
            ?? createdAt
        return lastActivity.addingTimeInterval(10 * 60)
    }

    func shouldIgnore(at now: Date) -> Bool {
        status == .selected && completedAt == nil && abandonedAt == nil && now >= activeUntil
    }

    func isActive(at now: Date) -> Bool {
        status == .selected && completedAt == nil && abandonedAt == nil && now < activeUntil
    }
}
