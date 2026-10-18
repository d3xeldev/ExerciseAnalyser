import CoreMotion
import EventKit
import HealthKit
import WatchKit

@MainActor
private final class QueryTicket<Value> {
    var continuation: CheckedContinuation<Value, Error>?
    var cancelQuery: (() -> Void)?
    var timeout: Task<Void, Never>?

    func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        timeout = nil
        cancelQuery = nil
        continuation.resume(with: result)
    }
}

@MainActor
final class HealthService {
    let store = HKHealthStore()
    private var observers: [HKObserverQuery] = []
    private var deliveryTask: Task<Void, Never>?
    private let identifiers: [HKQuantityTypeIdentifier] = [
        .stepCount, .activeEnergyBurned, .appleExerciseTime, .appleStandTime,
        .distanceWalkingRunning, .heartRate, .restingHeartRate, .heartRateVariabilitySDNN
    ]

    var readTypes: Set<HKObjectType> {
        Set(identifiers.compactMap(HKQuantityType.quantityType(forIdentifier:)) + [HKObjectType.workoutType(), HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!])
    }

    func authorizationConfigured() async throws -> Bool {
        guard HKHealthStore.isHealthDataAvailable() else { return false }
        // This reports whether setup is needed, never whether individual read grants were allowed.
        return try await store.statusForAuthorizationRequest(toShare: [], read: readTypes) == .unnecessary
    }

    func requestAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw NSError(domain: "Health", code: 1, userInfo: [NSLocalizedDescriptionKey: "Health data is unavailable on this device."])
        }
        try await store.requestAuthorization(toShare: [], read: readTypes)
    }

    func startObserving(onChange: @escaping @MainActor (String) async -> Void,
                        onRegistered: @escaping @MainActor (String) -> Void, onError: @escaping @MainActor (String) -> Void) {
        guard observers.isEmpty, HKHealthStore.isHealthDataAvailable() else { return }
        let types = readTypes.compactMap { $0 as? HKSampleType }.sorted { $0.identifier < $1.identifier }
        for type in types {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                Task { @MainActor in
                    defer { completion() }
                    if let error { onError("Health update: \(error.localizedDescription)"); return }
                    await onChange(type.identifier)
                }
            }
            observers.append(query)
            store.execute(query)
        }
        let previous = deliveryTask
        deliveryTask = Task { @MainActor in
            await previous?.value
            for type in types {
                do {
                    // Request the fastest delivery; watchOS transparently caps most of these types to hourly.
                    try await store.enableBackgroundDelivery(for: type, frequency: .immediate)
                    onRegistered(type.identifier)
                }
                catch { onError("Health background delivery (\(type.identifier)): \(error.localizedDescription)") }
            }
        }
    }

    func stopObserving() {
        observers.forEach(store.stop)
        observers.removeAll()
        // Serialize registration changes so a quick pause/resume cannot disable a newer registration.
        let previous = deliveryTask
        deliveryTask = Task { @MainActor in
            await previous?.value
            try? await store.disableAllBackgroundDelivery()
        }
    }

    private func execute<Value>(_ makeQuery: (QueryTicket<Value>) -> HKQuery) async throws -> Value {
        let ticket = QueryTicket<Value>()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                ticket.continuation = continuation
                let query = makeQuery(ticket)
                ticket.cancelQuery = { [store] in store.stop(query) }
                store.execute(query)
                ticket.timeout = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    ticket.cancelQuery?()
                    ticket.finish(.failure(NSError(domain: "Health", code: 2, userInfo: [NSLocalizedDescriptionKey: "Health query timed out."])))
                }
            }
        } onCancel: {
            Task { @MainActor in
                ticket.cancelQuery?()
                ticket.finish(.failure(CancellationError()))
            }
        }
    }

    private func samples(_ type: HKSampleType, from start: Date, to end: Date, limit: Int = HKObjectQueryNoLimit, localDeviceOnly: Bool = false) async throws -> [HKSample] {
        try await execute { ticket in
            let range = HKQuery.predicateForSamples(withStart: start, end: end)
            let predicate = localDeviceOnly ? NSCompoundPredicate(andPredicateWithSubpredicates: [range, HKQuery.predicateForObjects(from: [HKDevice.local()])]) : range
            return HKSampleQuery(sampleType: type, predicate: predicate, limit: limit,
                          sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)]) { _, samples, error in
                Task { @MainActor in
                    if let error { ticket.finish(.failure(error)) } else { ticket.finish(.success(samples ?? [])) }
                }
            }
        }
    }

    private func sum(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from start: Date, to end: Date) async throws -> Double? {
        try await execute { ticket in
            HKStatisticsQuery(quantityType: HKQuantityType(id), quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: end, options: .strictStartDate),
                              options: .cumulativeSum) { _, statistics, error in
                Task { @MainActor in
                    if let error { ticket.finish(.failure(error)) }
                    else { ticket.finish(.success(statistics?.sumQuantity()?.doubleValue(for: unit))) }
                }
            }
        }
    }

    private func dailySteps(to now: Date) async throws -> [ComplicationSnapshot.DailyTotal] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -6, to: today)!
        return try await execute { ticket in
            let query = HKStatisticsCollectionQuery(quantityType: HKQuantityType(.stepCount),
                quantitySamplePredicate: HKQuery.predicateForSamples(withStart: start, end: now, options: .strictStartDate),
                options: .cumulativeSum, anchorDate: today, intervalComponents: DateComponents(day: 1))
            query.initialResultsHandler = { _, collection, error in
                Task { @MainActor in
                    if let error { ticket.finish(.failure(error)); return }
                    var days: [ComplicationSnapshot.DailyTotal] = []
                    collection?.enumerateStatistics(from: start, to: now) { statistics, _ in
                        days.append(.init(date: statistics.startDate, value: statistics.sumQuantity()?.doubleValue(for: .count())))
                    }
                    ticket.finish(.success(days))
                }
            }
            return query
        }
    }

    private func latest(_ id: HKQuantityTypeIdentifier, unit: HKUnit, from start: Date, to end: Date) async throws -> Measurement? {
        guard let sample = try await samples(HKQuantityType(id), from: start, to: end, limit: 1, localDeviceOnly: id == .heartRate).first as? HKQuantitySample else { return nil }
        return .init(value: sample.quantity.doubleValue(for: unit), date: sample.endDate)
    }

    func populate(_ initial: ContextSnapshot, lightweight: Bool = false) async -> ContextSnapshot {
        var context = initial
        guard HKHealthStore.isHealthDataAvailable() else {
            context.issues.append("Health data is unavailable")
            return context
        }
        let now = context.date
        let today = Calendar.current.startOfDay(for: now)
        let week = now.addingTimeInterval(-7 * 86400)
        var recentStepsNoData = false
        var inferredRecentSteps = false
        // Run independent queries together to stay within the watch's short execution window.
        async let steps = dailySteps(to: now)
        async let recentSteps = sum(.stepCount, unit: .count(), from: now.addingTimeInterval(-15 * 60), to: now)
        async let energy = lightweight ? nil : sum(.activeEnergyBurned, unit: .kilocalorie(), from: today, to: now)
        async let exercise = lightweight ? nil : sum(.appleExerciseTime, unit: .minute(), from: today, to: now)
        async let stand = lightweight ? nil : sum(.appleStandTime, unit: .minute(), from: today, to: now)
        async let distance = lightweight ? nil : sum(.distanceWalkingRunning, unit: .meter(), from: today, to: now)
        async let hr = latest(.heartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: now.addingTimeInterval(-3600), to: now)
        async let resting = latest(.restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), from: week, to: now)
        async let hrv = lightweight ? nil : latest(.heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), from: now.addingTimeInterval(-86400), to: now)
        async let hrvSamples = lightweight ? [] : samples(HKQuantityType(.heartRateVariabilitySDNN), from: week, to: now.addingTimeInterval(-86400))
        async let sleep = samples(HKCategoryType(.sleepAnalysis), from: now.addingTimeInterval(-24 * 3600), to: now)
        async let workouts = samples(HKObjectType.workoutType(), from: now.addingTimeInterval(-86400), to: now, limit: 1)
        let recentEvent = ReminderPlanning.recentBusyEvent(context: context)
        let movementStart = min(now.addingTimeInterval(-6 * 3600), recentEvent?.start ?? now)
        async let movement = samples(HKQuantityType(.stepCount), from: movementStart, to: now)
        // Preserve usable signals if another read fails. HealthKit intentionally does not reveal read denial.
        do {
            context.stepHistory = try await steps
            context.stepsToday = context.stepHistory?.last?.value
        } catch { context.issues.append("Daily steps unavailable") }
        do { context.stepsRecent = try await recentSteps } catch {
            context.issues.append("Recent steps unavailable")
            let failure = error as NSError
            recentStepsNoData = failure.domain == HKErrorDomain && failure.code == HKError.Code.errorNoData.rawValue
            context.issues.append("Recent steps query: \(failure.domain) / \(failure.code): \(failure.localizedDescription)")
        }
        do { context.activeEnergy = try await energy } catch { context.issues.append("Active energy unavailable") }
        do { context.exerciseMinutes = try await exercise } catch { context.issues.append("Exercise minutes unavailable") }
        do { context.standMinutes = try await stand } catch { context.issues.append("Stand minutes unavailable") }
        do { context.distanceMeters = try await distance } catch { context.issues.append("Distance unavailable") }
        do { context.heartRate = try await hr } catch { context.issues.append("Heart rate unavailable") }
        do { context.restingHeartRate = try await resting } catch { context.issues.append("Resting heart rate unavailable") }
        do { context.heartRateVariability = try await hrv } catch { context.issues.append("HRV unavailable") }
        do {
            let values = try await hrvSamples.compactMap { ($0 as? HKQuantitySample)?.quantity.doubleValue(for: .secondUnit(with: .milli)) }.sorted()
            if values.count >= 3 { context.hrvBaseline = values[values.count / 2] }
        } catch { context.issues.append("HRV baseline unavailable") }
        do {
            let values = try await sleep.compactMap { $0 as? HKCategorySample }
            let asleepValues = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue]
            // Merge overlapping sources and sleep stages so sleep is never double-counted.
            let intervals = values.filter { asleepValues.contains($0.value) }.map {
                DateInterval(start: max($0.startDate, now.addingTimeInterval(-24 * 3600)), end: min($0.endDate, now))
            }.sorted { $0.start < $1.start }
            var merged: [DateInterval] = []
            for interval in intervals {
                if let last = merged.last, last.end >= interval.start {
                    merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
                } else { merged.append(interval) }
            }
            if !merged.isEmpty { context.sleepHours = merged.reduce(0) { $0 + $1.duration } / 3600 }
        } catch { context.issues.append("Sleep unavailable") }
        do { context.lastWorkoutEnd = try await workouts.first?.endDate } catch { context.issues.append("Workout history unavailable") }
        do {
            let stepSamples = try await movement.compactMap { $0 as? HKQuantitySample }
            if let event = recentEvent {
                // Count overlapping samples conservatively, including samples crossing event boundaries.
                // An empty/denied read is unknown; readable earlier history can establish an empty event window.
                let overlapping = stepSamples.filter { $0.startDate < event.end && $0.endDate > event.start }
                if let steps = StepEvidence.stepsDuringEvent(event, samples: stepSamples.map {
                    (interval: DateInterval(start: $0.startDate, end: $0.endDate), steps: $0.quantity.doubleValue(for: .count()))
                }) {
                    context.lastBusyEventActivity = .init(interval: event, steps: steps)
                }
                context.signalProvenance["busyEventSteps"] = .init(source: "HealthKit_overlapping_step_samples", unit: "count",
                    windowStart: event.start, windowEnd: event.end, sampleDate: overlapping.first?.endDate,
                    availability: context.lastBusyEventActivity == nil ? "no_data_or_denied" : (overlapping.isEmpty ? "inferred_empty_window_from_readable_history" : "available"))
            }
            context.lastMovement = stepSamples.first { $0.quantity.doubleValue(for: .count()) >= 20 }?.endDate
            inferredRecentSteps = StepEvidence.inferredEmptyRecentWindow(noData: recentStepsNoData,
                sampleIntervals: stepSamples.map { DateInterval(start: $0.startDate, end: $0.endDate) }, at: now)
            if inferredRecentSteps {
                context.stepsRecent = 0
                context.issues.removeAll { $0 == "Recent steps unavailable" }
            }
        } catch { context.issues.append("Movement history unavailable") }
        func provenance(_ key: String, value: Double?, unit: String, start: Date, end: Date? = nil, sampleDate: Date? = nil, error: String) {
            context.signalProvenance[key] = .init(source: "HealthKit", unit: unit, windowStart: start, windowEnd: end ?? now,
                                                  sampleDate: sampleDate, availability: context.issues.contains(error) ? "query_failed" : (value == nil ? "no_data_or_denied" : "available"))
        }
        provenance("stepsToday", value: context.stepsToday, unit: "count", start: today, error: "Daily steps unavailable")
        provenance("stepsRecent", value: context.stepsRecent, unit: "count", start: now.addingTimeInterval(-900), error: "Recent steps unavailable")
        if inferredRecentSteps {
            context.signalProvenance["stepsRecent"] = .init(source: "HealthKit_history_inference", unit: "count", windowStart: now.addingTimeInterval(-900), windowEnd: now,
                sampleDate: nil, availability: "inferred_empty_window_from_readable_history")
        }
        provenance("activeEnergy", value: context.activeEnergy, unit: "kcal", start: today, error: "Active energy unavailable")
        provenance("exerciseMinutes", value: context.exerciseMinutes, unit: "min", start: today, error: "Exercise minutes unavailable")
        provenance("standMinutes", value: context.standMinutes, unit: "min", start: today, error: "Stand minutes unavailable")
        provenance("distanceMeters", value: context.distanceMeters, unit: "m", start: today, error: "Distance unavailable")
        provenance("heartRate", value: context.heartRate?.value, unit: "bpm", start: now.addingTimeInterval(-3600), sampleDate: context.heartRate?.date, error: "Heart rate unavailable")
        provenance("restingHeartRate", value: context.restingHeartRate?.value, unit: "bpm", start: week, sampleDate: context.restingHeartRate?.date, error: "Resting heart rate unavailable")
        provenance("heartRateVariability", value: context.heartRateVariability?.value, unit: "ms", start: now.addingTimeInterval(-86400), sampleDate: context.heartRateVariability?.date, error: "HRV unavailable")
        provenance("hrvBaseline", value: context.hrvBaseline, unit: "ms", start: week, end: now.addingTimeInterval(-86400), error: "HRV baseline unavailable")
        provenance("sleepHours", value: context.sleepHours, unit: "h", start: now.addingTimeInterval(-86400), error: "Sleep unavailable")
        provenance("lastWorkoutEnd", value: context.lastWorkoutEnd?.timeIntervalSince1970, unit: "unix_seconds", start: now.addingTimeInterval(-86400), sampleDate: context.lastWorkoutEnd, error: "Workout history unavailable")
        provenance("lastMovement", value: context.lastMovement?.timeIntervalSince1970, unit: "unix_seconds", start: movementStart, sampleDate: context.lastMovement, error: "Movement history unavailable")
        if lightweight {
            for key in ["activeEnergy", "exerciseMinutes", "standMinutes", "distanceMeters", "heartRateVariability", "hrvBaseline"] {
                context.signalProvenance[key] = .init(source: "background_policy", unit: "not_collected", windowStart: now, windowEnd: now,
                    sampleDate: nil, availability: "omitted_for_background_budget")
            }
        }
        return context
    }
}

@MainActor
final class CalendarService {
    private let store = EKEventStore()

    func requestAccess() async throws -> Bool { try await store.requestFullAccessToEvents() }

    func populate(_ initial: ContextSnapshot) -> ContextSnapshot {
        var context = initial
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            context.issues.append("Calendar access has not been granted")
            return context
        }
        let now = context.date
        let end = now.addingTimeInterval(24 * 3600)
        let events = store.events(matching: store.predicateForEvents(withStart: now.addingTimeInterval(-86400), end: end, calendars: nil))
        // Only events explicitly marked Busy suppress reminders.
        // Keep recently ended intervals so the two-minute post-event plan can still be revalidated.
        let blocking = events.filter { $0.status != .canceled && $0.availability == .busy }
        context.calendarAvailable = true
        context.busyIntervals = blocking.map { DateInterval(start: $0.startDate, end: $0.endDate) }.sorted { $0.start < $1.start }
        let current = blocking.filter { $0.startDate <= now && $0.endDate > now }
        context.busy = !current.isEmpty
        context.busyUntil = current.map(\.endDate).max()
        let next = blocking.filter { $0.startDate > now }.map(\.startDate).min()
        context.freeMinutes = context.busy ? 0 : (next ?? end).timeIntervalSince(now) / 60
        // Never retain event titles, notes, attendees, locations, or calendar identifiers.
        return context
    }
}

@MainActor
final class MotionService {
    private let manager = CMMotionActivityManager()

    func requestAccess() async throws {
        guard CMMotionActivityManager.isActivityAvailable() else {
            throw NSError(domain: "Motion", code: 2, userInfo: [NSLocalizedDescriptionKey: "Motion activity is unavailable on this watch."])
        }
        // Permission prompts need time for the user's response; the background query timeout must not dismiss this flow.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.queryActivityStarting(from: Date().addingTimeInterval(-60), to: Date(), to: .main) { _, error in
                Task { @MainActor in
                    if let error, CMMotionActivityManager.authorizationStatus() != .authorized {
                        continuation.resume(throwing: error)
                    } else { continuation.resume() }
                }
            }
        }
    }

    func populate(_ initial: ContextSnapshot) async -> ContextSnapshot {
        var context = initial
        guard CMMotionActivityManager.isActivityAvailable(),
              CMMotionActivityManager.authorizationStatus() == .authorized else {
            context.issues.append("Motion history unavailable")
            return context
        }
        let ticket = QueryTicket<[CMMotionActivity]>()
        do {
            let activities: [CMMotionActivity] = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { continuation in
                    ticket.continuation = continuation
                    manager.queryActivityStarting(from: context.date.addingTimeInterval(-3 * 3600), to: context.date, to: .main) { values, error in
                        Task { @MainActor in
                            if let error { ticket.finish(.failure(error)) } else { ticket.finish(.success(values ?? [])) }
                        }
                    }
                    ticket.timeout = Task { @MainActor in
                        do { try await Task.sleep(for: .seconds(2)) } catch { return }
                        ticket.finish(.failure(NSError(domain: "Motion", code: 1, userInfo: [NSLocalizedDescriptionKey: "Motion query timed out"])))
                    }
                }
            } onCancel: {
                Task { @MainActor in ticket.finish(.failure(CancellationError())) }
            }
            let sorted = activities.sorted { $0.startDate < $1.startDate }
            guard let last = sorted.last, last.confidence != .low else { return context }
            context.motionObservedAt = context.date
            if last.automotive { context.motion = .automotive }
            else if last.cycling { context.motion = .cycling }
            else if last.running { context.motion = .running }
            else if last.walking { context.motion = .walking }
            else if last.stationary && !last.unknown {
                context.motion = .stationary
                var start = last.startDate
                for activity in sorted.reversed() {
                    guard activity.stationary && !activity.walking && !activity.running && !activity.cycling && !activity.automotive && !activity.unknown && activity.confidence != .low else { break }
                    start = activity.startDate
                }
                context.stationaryMinutes = min(180, max(0, context.date.timeIntervalSince(start) / 60))
            }
        } catch { context.issues.append("Motion history unavailable") }
        return context
    }
}

@MainActor
final class ContextService {
    let health = HealthService()
    let calendar = CalendarService()
    let motion = MotionService()

    func read(lightweight: Bool = false) async -> ContextSnapshot {
        let now = Date()
        var initial = ContextSnapshot(date: now, localHour: Calendar.current.component(.hour, from: now))
        let device = WKInterfaceDevice.current()
        device.isBatteryMonitoringEnabled = true
        initial.batteryLevel = device.batteryLevel >= 0 ? Double(device.batteryLevel) : nil
        initial.charging = device.batteryState == .charging || device.batteryState == .full
        initial.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let base = calendar.populate(initial)
        async let healthContext = health.populate(base, lightweight: lightweight)
        async let motionContext = motion.populate(base)
        var context = await healthContext
        let motionResult = await motionContext
        context.motion = motionResult.motion
        context.stationaryMinutes = motionResult.stationaryMinutes
        context.motionObservedAt = motionResult.motionObservedAt
        context.issues += motionResult.issues
        guard !Task.isCancelled else { return context }
        context = calendar.populate(context)
        context.signalProvenance["motion"] = .init(source: "CoreMotion", unit: "category", windowStart: now.addingTimeInterval(-3 * 3600), windowEnd: now,
                                                  sampleDate: context.motionObservedAt, availability: context.motionObservedAt == nil ? "unavailable_or_unknown" : "available")
        context.signalProvenance["calendar"] = .init(source: "EventKit", unit: "busy_intervals", windowStart: now.addingTimeInterval(-86400), windowEnd: now.addingTimeInterval(86400),
                                                    sampleDate: nil, availability: context.calendarAvailable ? "available" : "not_authorized")
        context.readCompletedAt = Date()
        return context
    }
}
