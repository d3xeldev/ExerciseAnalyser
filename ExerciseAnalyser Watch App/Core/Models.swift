import Foundation

enum Effort: String, Codable, CaseIterable, Sendable {
    case easy, moderate, challenge

    var title: String {
        switch self {
        case .easy: "Low"
        case .moderate: "Moderate"
        case .challenge: "High"
        }
    }
}

struct Exercise: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let title: String
    let effort: Effort
    let minutes: Int
    let symbol: String
    let instructions: String

    static let catalog: [Exercise] = [
        .init(id: "shoulders", title: "Shoulder reset", effort: .easy, minutes: 1, symbol: "figure.flexibility", instructions: "Sit or stand comfortably. Slowly roll your shoulders, then gently reach overhead. Keep the movement comfortable."),
        .init(id: "ankles", title: "Ankle mobility", effort: .easy, minutes: 1, symbol: "figure.cooldown", instructions: "While seated, gently circle each ankle and alternate lifting your toes and heels."),
        .init(id: "stroll", title: "Gentle stroll", effort: .easy, minutes: 2, symbol: "figure.walk", instructions: "Walk at an easy pace in a clear, safe space. Let your arms move naturally."),
        .init(id: "walk", title: "Walking break", effort: .moderate, minutes: 3, symbol: "figure.walk", instructions: "Take a steady walk at a comfortable pace. Choose a clear route and ease off whenever you need."),
        .init(id: "mobility", title: "Mobility flow", effort: .moderate, minutes: 3, symbol: "figure.flexibility", instructions: "Alternate gentle side reaches, shoulder rolls, and standing heel raises. Use a stable support if needed."),
        .init(id: "sit_stand", title: "Chair movement", effort: .moderate, minutes: 3, symbol: "figure.strengthtraining.functional", instructions: "Use a stable chair. Slowly stand up and sit down a few times, resting between sets. Use your hands for support if needed."),
        .init(id: "brisk", title: "Brisk walk", effort: .challenge, minutes: 5, symbol: "figure.walk", instructions: "Walk a little faster than usual on a safe, level route. Keep a pace where you can still speak comfortably and slow down as needed."),
        .init(id: "circuit", title: "Movement circuit", effort: .challenge, minutes: 5, symbol: "figure.strengthtraining.functional", instructions: "Alternate easy chair stands, wall push-ups, and marching in place. Take generous rests and skip any uncomfortable movement."),
        .init(id: "march", title: "March & reach", effort: .challenge, minutes: 5, symbol: "figure.mixed.cardio", instructions: "Alternate marching in place with comfortable arm reaches. Keep your balance, take breaks, and reduce the pace whenever needed.")
    ]
}

struct Settings: Codable, Equatable, Sendable {
    static let unlimitedDailyLimit = -1

    var monitoring = false
    var explorationRate = 0.3
    var inactivityMinutes = 30
    var cooldownMinutes = 60
    var dailyLimit = 3
    var startHour = 9
    var endHour = 21
    var requireCalendar = true
    var excludedExerciseIDs: Set<String> = []
}

struct Measurement: Codable, Equatable, Sendable {
    let value: Double
    let date: Date

    func fresh(at now: Date, within seconds: TimeInterval) -> Bool {
        (0...seconds).contains(now.timeIntervalSince(date))
    }
}

enum MotionKind: String, Codable, Sendable {
    case stationary, walking, running, cycling, automotive, unknown
}

struct BusyEventActivity: Codable, Sendable {
    let interval: DateInterval
    let steps: Double
}

struct ContextSnapshot: Codable, Sendable {
    var date: Date
    var timeZoneIdentifier: String = TimeZone.current.identifier
    var localHour: Int
    var calendarAvailable = false
    var busy = false
    var freeMinutes: Double?
    var busyUntil: Date?
    var busyIntervals: [DateInterval]?
    var lastBusyEventActivity: BusyEventActivity?
    var stepsToday: Double?
    var stepsRecent: Double?
    var activeEnergy: Double?
    var exerciseMinutes: Double?
    var standMinutes: Double?
    var distanceMeters: Double?
    var heartRate: Measurement?
    var restingHeartRate: Measurement?
    var heartRateVariability: Measurement?
    var hrvBaseline: Double?
    var sleepHours: Double?
    var lastWorkoutEnd: Date?
    var lastMovement: Date?
    var motion: MotionKind = .unknown
    var stationaryMinutes: Double?
    var motionObservedAt: Date?
    var batteryLevel: Double?
    var charging = false
    var lowPower = false
    var issues: [String] = []
    var signalProvenance: [String: SignalProvenance] = [:]
    var readCompletedAt: Date?

    func isTimelyForDecision(at now: Date) -> Bool {
        (0...15).contains(now.timeIntervalSince(date))
    }

    // An estimate requires positive evidence that the watch is being worn.
    // No samples (including denied reads) never means zero activity.
    var inactivityEstimate: Double? {
        guard let heartRate, heartRate.fresh(at: date, within: 20 * 60) else { return nil }
        if motion == .stationary, let stationaryMinutes, let motionObservedAt,
           (0...300).contains(date.timeIntervalSince(motionObservedAt)) {
            let sinceMovement = lastMovement.map { max(0, date.timeIntervalSince($0) / 60) }
            return min(stationaryMinutes, sinceMovement ?? stationaryMinutes)
        }
        guard let stepsRecent, stepsRecent < 20, let lastMovement else { return nil }
        return max(0, date.timeIntervalSince(lastMovement) / 60)
    }
}

struct SignalProvenance: Codable, Sendable {
    let source: String
    let unit: String
    let windowStart: Date
    let windowEnd: Date
    let sampleDate: Date?
    let availability: String
}

struct OpportunityDecision: Codable, Sendable {
    let shouldNotify: Bool
    let score: Double
    let reasons: [String]
    let availableMinutes: Double
    var inactivityMinutes: Double?
    var scoreContributions: [String: Double] = [:]
}

enum SelectionMethod: String, Codable, Sendable {
    case learned, randomExploration, coldStartRandom

    var title: String {
        switch self {
        case .learned: "Personalized"
        case .randomExploration: "Try something different"
        case .coldStartRandom: "Discover your favorites"
        }
    }
}

struct ExerciseOption: Codable, Identifiable, Sendable {
    var id: String { exercise.id }
    let exercise: Exercise
    let method: SelectionMethod
    let candidateIDs: [String]
    let preferenceScores: [String: Double]
    let selectionProbability: Double
    var exposureCounts: [String: Int] = [:]
    var selectionCounts: [String: Int] = [:]
}

enum PromptStatus: String, Codable, Sendable {
    case prepared, scheduled, selected, dismissed, expired, cancelled, failed
}

struct ExercisePrompt: Identifiable, Codable, Sendable {
    let id: UUID
    let createdAt: Date
    let expiresAt: Date
    let context: ContextSnapshot
    let decision: OpportunityDecision
    let settings: Settings
    let policyVersion: String
    let method: SelectionMethod
    let methodProbability: Double
    let options: [ExerciseOption]
    var status: PromptStatus = .prepared
    var scheduledAt: Date?
    var selectedExerciseID: String?
    var respondedAt: Date?
    var completedAt: Date?
    var abandonedAt: Date?
    var exerciseSession: ExerciseSession?
    var randomizationSeed: String?
    var opportunityCheckID: String?
    var plannedFor: Date?
    var deliveryReason: String?
    var cancelledAt: Date?

    // scheduledAt is request acceptance, not delivery. Cancelled future requests are not exposures.
    var notificationDate: Date? {
        guard let scheduledAt, status != .failed else { return nil }
        if let plannedFor, status == .cancelled, (cancelledAt ?? .distantPast) < plannedFor { return nil }
        return plannedFor ?? scheduledAt
    }

    func isAvailable(at now: Date) -> Bool {
        status == .scheduled && (plannedFor ?? createdAt) <= now && expiresAt > now
    }

    var slateAssignmentProbability: Double {
        options.reduce(methodProbability) { $0 * $1.selectionProbability }
    }
}

struct StudyEvent: Identifiable, Codable, Sendable {
    var id = UUID()
    var date: Date
    var kind: String
    var promptID: UUID?
    var exerciseID: String?
    var source: String
    var detail: String?
    var context: ContextSnapshot?
    var decision: OpportunityDecision?
    var policyVersion: String = "epsilon-greedy-1"
    var settings: Settings?
    var sessionID: UUID?
    var attributes: [String: String] = [:]
    var sequence: Int?
    var participantID: UUID?
}

struct StudyState: Codable, Sendable {
    var schemaVersion = 1
    var participantID = UUID()
    var settings = Settings()
    var prompts: [ExercisePrompt] = []
    var events: [StudyEvent] = []
}
