#if DEBUG
import Foundation

enum WatchPreviewData {
    enum TimerState { case ready, running, paused, checking, detected, littleMovement, unknown, saved }

    static func model(timer: TimerState? = nil, empty: Bool = false) -> AppModel {
        guard !empty else { return .preview() }
        let now = Date()
        var context = ContextSnapshot(date: now, localHour: 14)
        context.calendarAvailable = true
        context.freeMinutes = 45
        context.stepsToday = 6248
        context.stepsRecent = 8
        context.exerciseMinutes = 24
        context.standMinutes = 32
        context.activeEnergy = 210
        context.distanceMeters = 4200
        context.heartRate = .init(value: 72, date: now)
        context.sleepHours = 7.4
        context.batteryLevel = 0.78
        context.motion = .stationary
        context.stationaryMinutes = 35
        context.motionObservedAt = now
        var state = StudyState()
        state.settings.monitoring = true
        let options = Effort.allCases.map { effort in
            let exercise = Exercise.catalog.first { $0.effort == effort }!
            return ExerciseOption(exercise: exercise, method: .coldStartRandom, candidateIDs: [exercise.id],
                                  preferenceScores: [:], selectionProbability: 1)
        }
        var prompt = ExercisePrompt(id: UUID(), createdAt: now.addingTimeInterval(-120), expiresAt: now.addingTimeInterval(3600),
            context: context, decision: .init(shouldNotify: true, score: 0.8, reasons: ["Space for a movement break"], availableMinutes: 45),
            settings: state.settings, policyVersion: "preview", method: .coldStartRandom, methodProbability: 1, options: options,
            status: .scheduled, scheduledAt: now.addingTimeInterval(-120))
        if let timer {
            prompt.status = .selected
            prompt.selectedExerciseID = options[0].id
            prompt.respondedAt = now
            var session = ExerciseSession()
            switch timer {
            case .ready: break
            case .running: session.start(at: now.addingTimeInterval(-15))
            case .paused:
                session.start(at: now.addingTimeInterval(-25))
                session.pause(at: now.addingTimeInterval(-10))
            case .checking, .detected, .littleMovement, .unknown, .saved:
                session.start(at: now.addingTimeInterval(-60))
                session.pause(at: now)
                session.endedAt = now
                if timer != .checking {
                    session.assessment = .init(outcome: timer == .littleMovement ? .littleMovement : (timer == .unknown ? .inconclusive : .movementDetected),
                        evidence: .init(wristMovementSeconds: 35, wristObservedSeconds: 60),
                        explanation: "Sample movement assessment for UI previews.", policyVersion: "preview")
                }
                if timer == .saved { prompt.completedAt = now }
            }
            prompt.exerciseSession = session
        }
        state.prompts = [prompt]
        state.events = [.init(date: now, kind: "opportunity_evaluated", source: "preview", context: context)]
        return .preview(state: state, context: context)
    }
}
#endif
