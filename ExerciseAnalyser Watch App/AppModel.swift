import HealthKit
import EventKit
import CoreMotion
import Observation
import UserNotifications
import WatchKit
import WidgetKit

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var revision = 0
    private(set) var checking = false
    private(set) var requestingAccess = false
    private(set) var context: ContextSnapshot?
    private(set) var decision: OpportunityDecision?
    private(set) var notificationAccess = false
    private(set) var calendarAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
    private(set) var motionAccess = CMMotionActivityManager.authorizationStatus() == .authorized
    private(set) var healthConfigured = false
    private(set) var refreshingAccess = false
    var message: String?
    var exportURLs: [URL] = []
    private(set) var navigationRequest = UUID()
    private(set) var requestedPromptID: UUID?
    private(set) var assessingExercise = false
    @ObservationIgnored private let exerciseEvidence = ExerciseEvidenceService()
    @ObservationIgnored private var store: StudyStore?
    @ObservationIgnored private let emptyState = StudyState()
    @ObservationIgnored private let services = ContextService()
    @ObservationIgnored private let notifications = NotificationService()
    @ObservationIgnored private var calendarObserver: NSObjectProtocol?
    @ObservationIgnored private var pendingRefresh: RefreshRequest?
    @ObservationIgnored private var lastRefreshSubmission: Date?
    @ObservationIgnored private var evaluationTask: Task<Void, Never>?
    @ObservationIgnored private var evaluationStartedAt: Date?
    @ObservationIgnored private var evaluationID: UUID?
    @ObservationIgnored private var evaluationCompletion: EvaluationCompletion?
    @ObservationIgnored private var pendingTriggers: Set<String> = []
    @ObservationIgnored private var lastComplicationError: String?
    @ObservationIgnored private let sessionID = UUID()

    var state: StudyState { _ = revision; return store?.state ?? emptyState }
    var dataAvailable: Bool { store != nil }
    var settings: Settings { state.settings }
    var currentPrompt: ExercisePrompt? {
        state.prompts.last { $0.isAvailable(at: Date()) }
    }
    var activePrompt: ExercisePrompt? {
        state.prompts.last { $0.status == .selected && $0.completedAt == nil && $0.abandonedAt == nil }
    }
    var nextRefreshDate: Date? { _ = revision; return pendingRefresh?.preferredDate }

    private var executionState: String {
        switch WKApplication.shared().applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }

    private init() {
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            store = try StudyStore(url: directory.appendingPathComponent("Study/study.json"))
            store?.sessionID = sessionID
        } catch { message = "Study data could not be opened: \(error.localizedDescription) Monitoring is disabled to protect existing logs." }
        if let data = UserDefaults.standard.data(forKey: "pendingBackgroundRefresh") {
            pendingRefresh = try? JSONDecoder().decode(RefreshRequest.self, from: data)
        }
        if let previous = state.events.last(where: { $0.context != nil }) {
            context = previous.context
            decision = previous.decision
        }
        notifications.onResponse = { [weak self] id, action, date in await self?.handleResponse(id: id, action: action, at: date) }
        notifications.onForeground = { [weak self] id in
            self?.record(.init(date: Date(), kind: "foreground_received", promptID: id, source: "notification"))
        }
        notifications.registerCategories(for: state.prompts)
        record(.init(date: Date(), kind: "session_started", source: "lifecycle", attributes: [
            "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown",
            "osVersion": WKInterfaceDevice.current().systemVersion,
            "deviceModel": WKInterfaceDevice.current().model,
            "timeZone": TimeZone.current.identifier,
            "locale": Locale.current.identifier
        ]))
        calendarObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.calendarChanged() }
        }
        publishComplications()
        if settings.monitoring {
            // Do not replace the task that launched us before its callback is consumed.
            // Foreground entry, HealthKit delivery, and refresh callbacks arm the next request.
            startObservers()
        }
    }

    private func mutate(_ change: (inout StudyState) throws -> Void) throws {
        guard let store else { throw StudyStoreError.unsupportedSchema }
        try store.transaction(change)
        revision += 1
        exportURLs = []
    }

    private func persistEvent(_ event: StudyEvent) throws {
        guard let store else { throw StudyStoreError.unsupportedSchema }
        var enriched = event
        enriched.sessionID = sessionID
        enriched.settings = settings
        enriched.attributes["applicationState"] = executionState
        enriched.attributes["opportunityPolicy"] = ReminderPlanning.policyVersion
        try store.appendEvent(enriched)
        revision += 1
        exportURLs = []
    }

    private func record(_ event: StudyEvent) {
        do { try persistEvent(event) }
        catch { message = "Could not save study data: \(error.localizedDescription)" }
    }

    func updateSettings(_ change: (inout Settings) -> Void) {
        var updated = settings
        change(&updated)
        do {
            try mutate { state in
                state.settings = updated
                state.events.append(.init(date: Date(), kind: "settings_changed", source: "app",
                                          detail: String(data: try StudyStore.encoder.encode(updated), encoding: .utf8)))
                for index in state.prompts.indices where [.prepared, .scheduled].contains(state.prompts[index].status) {
                    state.prompts[index].status = .cancelled
                    state.prompts[index].cancelledAt = Date()
                    state.events.append(.init(date: Date(), kind: "cancelled_settings_changed", promptID: state.prompts[index].id, source: "app"))
                }
            }
            notifications.remove(state.prompts.filter { $0.status == .cancelled }.map(\.id))
            if updated.monitoring {
                scheduleRefresh()
                startObservers()
                Task { await evaluate(source: "settings_changed") }
            } else {
                services.health.stopObserving()
                setPendingRefresh(nil)
                record(.init(date: Date(), kind: "background_refresh_deactivated", source: "scheduler",
                             detail: "A previously requested OS callback may still arrive; it will not collect data while paused."))
            }
            publishComplications()
        } catch { message = error.localizedDescription }
    }

    func requestHealth() async {
        guard !requestingAccess, !healthConfigured else { return }
        requestingAccess = true
        defer { requestingAccess = false }
        record(.init(date: Date(), kind: "permission_requested", source: "app", detail: "health"))
        do {
            try await services.health.requestAccess()
            healthConfigured = true
            record(.init(date: Date(), kind: "permission_result", source: "app", detail: "Health authorization flow completed. Individual read grants are not disclosed."))
            message = "Health configured. Your permission choices are saved. Apple does not disclose individual read grants; available samples appear in Signals."
            if settings.monitoring { services.health.stopObserving(); startObservers() }
            await evaluate(source: "health_permission_changed")
        } catch {
            record(.init(date: Date(), kind: "permission_error", source: "health", detail: error.localizedDescription))
            message = error.localizedDescription
        }
    }

    func requestCalendar() async {
        guard !requestingAccess, !calendarAccess else { return }
        requestingAccess = true
        defer { requestingAccess = false }
        record(.init(date: Date(), kind: "permission_requested", source: "app", detail: "calendar"))
        do {
            let allowed = try await services.calendar.requestAccess()
            calendarAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
            record(.init(date: Date(), kind: "permission_result", source: "calendar", detail: allowed ? "full_access" : "not_granted"))
            message = calendarAccess ? "Calendar enabled. Only busy/free times are retained." : "Calendar permission was not granted."
            await evaluate(source: "calendar_permission_changed")
        } catch {
            record(.init(date: Date(), kind: "permission_error", source: "calendar", detail: error.localizedDescription))
            message = error.localizedDescription
        }
    }

    func requestMotion() async {
        guard !requestingAccess, !motionAccess else { return }
        requestingAccess = true
        defer { requestingAccess = false }
        record(.init(date: Date(), kind: "permission_requested", source: "app", detail: "motion"))
        do {
            try await services.motion.requestAccess()
            motionAccess = CMMotionActivityManager.authorizationStatus() == .authorized
            record(.init(date: Date(), kind: "permission_result", source: "motion", attributes: ["authorizationStatus": String(CMMotionActivityManager.authorizationStatus().rawValue)]))
            message = motionAccess ? "Motion enabled. Activity history will appear when available." : "Motion permission was not granted. Check Motion & Fitness access in Settings."
            await evaluate(source: "motion_permission_changed")
        } catch {
            motionAccess = CMMotionActivityManager.authorizationStatus() == .authorized
            record(.init(date: Date(), kind: "permission_error", source: "motion", detail: error.localizedDescription))
            message = error.localizedDescription
        }
    }

    func requestNotifications() async {
        guard !requestingAccess, !notificationAccess else { return }
        requestingAccess = true
        defer { requestingAccess = false }
        record(.init(date: Date(), kind: "permission_requested", source: "app", detail: "notifications"))
        do {
            _ = try await notifications.requestAccess()
            notificationAccess = await notifications.isAuthorized()
            record(.init(date: Date(), kind: "permission_result", source: "notifications", detail: notificationAccess ? "enabled" : "disabled"))
            message = notificationAccess ? "Notifications enabled." : "Notifications are disabled. You can enable them in Settings."
            await evaluate(source: "notification_permission_changed")
        } catch {
            record(.init(date: Date(), kind: "permission_error", source: "notifications", detail: error.localizedDescription))
            message = error.localizedDescription
        }
    }

    func refreshAccessStatus() async {
        calendarAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        motionAccess = CMMotionActivityManager.authorizationStatus() == .authorized
        guard !refreshingAccess else { return }
        refreshingAccess = true
        defer { refreshingAccess = false }
        notificationAccess = await notifications.isAuthorized()
        if let configured = try? await services.health.authorizationConfigured() {
            healthConfigured = configured
        }
    }

    private func startObservers() {
        services.health.startObserving(onChange: { [weak self] type in
            self?.record(.init(date: Date(), kind: "health_observer_received", source: "health", attributes: ["sampleType": type]))
            await self?.evaluate(source: "health_update", attributes: ["sampleType": type])
        }, onRegistered: { [weak self] type in
            self?.record(.init(date: Date(), kind: "health_background_registered", source: "health", attributes: [
                "sampleType": type, "requestedFrequency": "immediate", "effectiveFrequency": "system_limited"
            ]))
        }, onError: { [weak self] error in
            self?.message = error
            self?.record(.init(date: Date(), kind: "health_background_error", source: "health", detail: error))
        })
    }

    func foreground() async {
        guard WKApplication.shared().applicationState == .active else { return }
        record(.init(date: Date(), kind: "foreground_entered", source: "lifecycle"))
        scheduleRefresh(recover: true)
        await tickExercise()
        await refreshAccessStatus()
        await reconcile()
        if settings.monitoring { startObservers() }
        await evaluate(source: "foreground")
        await inspectComplicationConfigurations()
    }

    func enteredBackground() {
        record(.init(date: Date(), kind: "background_entered", source: "lifecycle"))
        scheduleRefresh(recover: true)
    }

    func backgroundExpired(reason: String = "watchOS_expiration") {
        evaluationTask?.cancel()
        evaluationCompletion?.finish()
        pendingTriggers.removeAll()
        record(.init(date: Date(), kind: "background_refresh_expired", source: "watchOS",
                     detail: "Refresh execution ended; in-flight evaluation was cancelled.", attributes: ["reason": reason]))
    }

    private func reconcile() async {
        guard let store else { return }
        do {
            try store.expire(at: Date())
            let known = await notifications.knownRequestIDs()
            try mutate { state in
                for index in state.prompts.indices where state.prompts[index].status == .prepared {
                    let found = known.contains(state.prompts[index].id.uuidString)
                    state.prompts[index].status = found ? .scheduled : .failed
                    if found { state.prompts[index].scheduledAt = state.prompts[index].createdAt }
                    state.events.append(.init(date: Date(), kind: "schedule_reconciled", promptID: state.prompts[index].id, source: "launch",
                                              detail: found ? "Request found in notification center" : "Request not found; delivery is unknown"))
                }
            }
            try cancelPlannedReminders(reason: "Migrated to delivery-time calendar and movement checks") { _ in true }
            notifications.remove(state.prompts.filter { [.expired, .cancelled, .failed].contains($0.status) }.map(\.id))
        } catch { message = error.localizedDescription }
    }

    func evaluate(source: String, attributes: [String: String] = [:]) async {
        guard dataAvailable, settings.monitoring else { publishComplications(); return }
        scheduleRefresh()
        if let started = evaluationStartedAt, Date().timeIntervalSince(started) >= 12 {
            evaluationTask?.cancel()
            evaluationCompletion?.finish()
            evaluationTask = nil
            evaluationID = nil
            pendingTriggers.removeAll()
            record(.init(date: Date(), kind: "check_recovered", source: source,
                         detail: "Discarded an evaluation left waiting across execution windows.",
                         attributes: ["elapsedSeconds": String(Date().timeIntervalSince(started))]))
        }
        if evaluationTask != nil {
            if source != "foreground" { pendingTriggers.insert(source) }
            record(.init(date: Date(), kind: "check_coalesced", source: source,
                         detail: "Awaiting the active check; foreground changes may receive one follow-up pass.", attributes: attributes))
            await evaluationCompletion?.wait()
            return
        }
        checking = true
        let id = UUID()
        let completion = EvaluationCompletion()
        evaluationCompletion = completion
        evaluationID = id
        evaluationStartedAt = Date()
        let lightweight = WKApplication.shared().applicationState != .active
        let task = Task { @MainActor in
            defer { completion.finish() }
            await performEvaluation(source: source, attributes: attributes, lightweight: lightweight)
            if !pendingTriggers.isEmpty, settings.monitoring, !Task.isCancelled,
               WKApplication.shared().applicationState == .active {
                let triggers = pendingTriggers.sorted().joined(separator: ",")
                pendingTriggers.removeAll()
                await performEvaluation(source: "coalesced_update", attributes: ["triggers": triggers], lightweight: false)
            }
        }
        evaluationTask = task
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(lightweight ? 6 : 12)) } catch { return }
            guard evaluationID == id else { return }
            task.cancel()
            completion.finish()
            record(.init(date: Date(), kind: "check_deadline_exceeded", source: source,
                         detail: "Cancelled collection to release the background execution window."))
        }
        await completion.wait()
        deadline.cancel()
        guard evaluationID == id else { return }
        evaluationID = nil
        evaluationCompletion = nil
        evaluationStartedAt = nil
        evaluationTask = nil
        checking = false
        if !pendingTriggers.isEmpty {
            record(.init(date: Date(), kind: "check_deferred_to_next_wake", source: "scheduler",
                         detail: "Yielding after one background pass or two foreground passes; further changes await the next wake.",
                         attributes: ["triggers": pendingTriggers.sorted().joined(separator: ",")]))
            pendingTriggers.removeAll()
        }
        scheduleRefresh()
        publishComplications()
    }

    private func performEvaluation(source: String, attributes: [String: String], lightweight: Bool) async {
        guard let store, settings.monitoring, !Task.isCancelled else { return }
        do {
            let checkID = UUID().uuidString
            record(.init(date: Date(), kind: "check_started", source: source, attributes: attributes.merging(["checkID": checkID]) { _, new in new }))
            try store.expire(at: Date())
            revision += 1
            notifications.remove(state.prompts.filter { $0.status == .expired }.map(\.id))
            let evaluationSettings = settings
            var snapshot = await services.read(lightweight: lightweight)
            guard !Task.isCancelled else {
                record(.init(date: Date(), kind: "check_cancelled", source: source, detail: "Background execution expired", attributes: ["checkID": checkID]))
                return
            }
            guard snapshot.isTimelyForDecision(at: Date()) else {
                record(.init(date: Date(), kind: "check_cancelled", source: source,
                             detail: "Signal collection exceeded 15 seconds; suspended or delayed context is not used for a notification.",
                             attributes: ["checkID": checkID, "elapsedSeconds": String(Date().timeIntervalSince(snapshot.date))]))
                return
            }
            guard settings == evaluationSettings else {
                record(.init(date: Date(), kind: "check_cancelled", source: source, detail: "Settings changed during signal collection", attributes: ["checkID": checkID]))
                return
            }
            // Re-read calendar after asynchronous health queries before any notification is submitted.
            snapshot = services.calendar.populate(snapshot)
            context = snapshot
            try cancelPlannedReminders(reason: "Future reminders require fresh calendar and movement checks") { _ in true }
            let result = OpportunityEngine.evaluate(snapshot, settings: settings, history: state.prompts)
            decision = result
            notificationAccess = await notifications.isAuthorized()
            guard settings == evaluationSettings, !Task.isCancelled, snapshot.isTimelyForDecision(at: Date()) else { return }
            try persistEvent(.init(date: Date(), kind: "opportunity_evaluated", source: source,
                                                detail: notificationAccess ? nil : "Notifications unavailable", context: snapshot, decision: result,
                                                settings: evaluationSettings, sessionID: sessionID, attributes: [
                                                    "checkID": checkID,
                                                    "opportunityPolicy": ReminderPlanning.policyVersion,
                                                    "effectiveInactivityMinutes": String(ReminderPlanning.inactivityTarget(settings: settings, context: snapshot, history: state.prompts)),
                                                    "applicationState": executionState,
                                                    "collectionMode": lightweight ? "background_essential" : "foreground_full",
                                                    "queryDurationSeconds": String((snapshot.readCompletedAt ?? Date()).timeIntervalSince(snapshot.date)),
                                                    "notificationAccess": String(notificationAccess),
                                                    "calendarAuthorization": String(EKEventStore.authorizationStatus(for: .event).rawValue),
                                                    "motionAuthorization": String(CMMotionActivityManager.authorizationStatus().rawValue),
                                                    "healthReadAuthorization": "not_disclosed_by_HealthKit"
                                                ]))
            guard !Task.isCancelled, settings.monitoring, notificationAccess else { return }
            guard result.shouldNotify else { return }
            let seed = UInt64.random(in: UInt64.min...UInt64.max)
            var rng = StudyRandom(seed: seed)
            guard var prompt = RecommendationEngine.makePrompt(context: snapshot, decision: result, settings: settings, history: state.prompts,
                                                                randomizationSeed: String(seed),
                                                                deliveryReason: ReminderPlanning.recentBusyEvent(context: snapshot) == nil ? "immediate_opportunity" : "after_busy_event", rng: &rng) else {
                try mutate { $0.events.append(.init(date: Date(), kind: "no_eligible_options", source: source, detail: "Enable at least one exercise per effort level.")) }
                message = "Enable at least one exercise at each effort level."
                return
            }
            prompt.opportunityCheckID = checkID
            try mutate { state in
                state.prompts.append(prompt)
                state.events.append(.init(date: Date(), kind: "prompt_prepared", promptID: prompt.id, source: source))
            }
            notifications.registerCategories(for: state.prompts)
            do {
                try await notifications.schedule(prompt)
                // A settings change may cancel the prompt while notification scheduling is in flight.
                guard !Task.isCancelled, settings.monitoring, state.prompts.first(where: { $0.id == prompt.id })?.status != .cancelled else {
                    notifications.remove([prompt.id])
                    if Task.isCancelled {
                        try mutate { state in
                            guard let index = state.prompts.firstIndex(where: { $0.id == prompt.id }),
                                  state.prompts[index].status == .prepared else { return }
                            state.prompts[index].status = .cancelled
                            state.prompts[index].cancelledAt = Date()
                            state.events.append(.init(date: Date(), kind: "notification_cancelled_deadline", promptID: prompt.id, source: source))
                        }
                    }
                    return
                }
                try mutate { state in
                    guard let index = state.prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
                    if state.prompts[index].status == .prepared { state.prompts[index].status = .scheduled }
                    state.prompts[index].scheduledAt = Date()
                    state.events.append(.init(date: Date(), kind: "notification_scheduled", promptID: prompt.id, source: source,
                                              detail: "Accepted by notification center; delivery is not guaranteed."))
                }
            } catch {
                notifications.remove([prompt.id])
                try mutate { state in
                    guard let index = state.prompts.firstIndex(where: { $0.id == prompt.id }) else { return }
                    state.prompts[index].status = .failed
                    state.events.append(.init(date: Date(), kind: "notification_failed", promptID: prompt.id, source: source, detail: error.localizedDescription))
                }
                throw error
            }
        } catch {
            record(.init(date: Date(), kind: "check_failed", source: source, detail: error.localizedDescription))
            message = "Could not complete check: \(error.localizedDescription)"
        }
    }

    private func cancelPlannedReminders(reason: String, where shouldCancel: (ExercisePrompt) -> Bool) throws {
        let ids = state.prompts.filter {
            [.prepared, .scheduled].contains($0.status) && ($0.plannedFor.map { $0 > Date() } ?? false) && shouldCancel($0)
        }.map(\.id)
        guard !ids.isEmpty else { return }
        notifications.remove(ids)
        try mutate { state in
            for index in state.prompts.indices where ids.contains(state.prompts[index].id) {
                state.prompts[index].status = .cancelled
                state.prompts[index].cancelledAt = Date()
                state.events.append(.init(date: Date(), kind: "planned_reminder_cancelled", promptID: state.prompts[index].id, source: "planner", detail: reason))
            }
        }
    }

    private func calendarChanged() async {
        do {
            try cancelPlannedReminders(reason: "Calendar changed before the planned reminder") { _ in true }
        } catch { message = "Could not save calendar-plan changes: \(error.localizedDescription)" }
        publishComplications()
        await evaluate(source: "calendar_changed")
    }

    func triggerManualIntervention() {
        if let prompt = activePrompt ?? currentPrompt {
            requestedPromptID = prompt.id
            navigationRequest = UUID()
            return
        }
        let now = Date()
        let snapshot = context.flatMap { $0.isTimelyForDecision(at: now) ? $0 : nil }
            ?? ContextSnapshot(date: now, localHour: Calendar.current.component(.hour, from: now))
        // A user-requested break bypasses automatic timing and inactivity gates.
        let manualDecision = OpportunityDecision(shouldNotify: true, score: 0, reasons: ["Manually requested"],
                                                 availableMinutes: Double((Exercise.catalog.map(\.minutes).max() ?? 0) + 2))
        let seed = UInt64.random(in: UInt64.min...UInt64.max)
        var rng = StudyRandom(seed: seed)
        guard var prompt = RecommendationEngine.makePrompt(context: snapshot, decision: manualDecision, settings: settings,
                                                            history: state.prompts, randomizationSeed: String(seed),
                                                            deliveryReason: "manual_intervention", rng: &rng) else {
            message = "Enable at least one exercise at each effort level."
            return
        }
        // Make the invitation available in-app without scheduling a notification.
        prompt.status = .scheduled
        do {
            try mutate { state in
                state.prompts.append(prompt)
                state.events.append(.init(date: now, kind: "manual_intervention", promptID: prompt.id, source: "app"))
            }
            requestedPromptID = prompt.id
            navigationRequest = UUID()
        } catch { message = error.localizedDescription }
    }

    func choose(promptID: UUID, exerciseID: String?, source: String = "app", at date: Date = Date()) {
        defer { publishComplications(); scheduleRefresh() }
        guard let store else { return }
        if let activePrompt, let exerciseID {
            if activePrompt.id == promptID && activePrompt.selectedExerciseID == exerciseID {
                requestedPromptID = promptID
                navigationRequest = UUID()
            } else {
                message = "Finish your current break before choosing another."
            }
            return
        }
        do {
            let accepted = try store.respond(promptID: promptID, exerciseID: exerciseID, source: source, at: date)
            revision += 1
            exportURLs = []
            if accepted {
                notifications.remove([promptID])
                requestedPromptID = exerciseID == nil ? nil : promptID
                navigationRequest = UUID()
            }
        } catch {
            record(.init(date: date, kind: "response_rejected", promptID: promptID, exerciseID: exerciseID, source: source, detail: error.localizedDescription))
            message = error.localizedDescription
            notifications.remove([promptID])
        }
    }

    private func handleResponse(id: UUID, action: String, at date: Date) async {
        if action == "exercise_timer" {
            requestedPromptID = id
            navigationRequest = UUID()
            await tickExercise()
        } else if action == UNNotificationDefaultActionIdentifier {
            requestedPromptID = id
            navigationRequest = UUID()
            do {
                try mutate { state in
                    if let index = state.prompts.firstIndex(where: { $0.id == id && $0.status == .prepared }) {
                        state.prompts[index].status = .scheduled
                        state.prompts[index].scheduledAt = state.prompts[index].createdAt
                        state.events.append(.init(date: date, kind: "schedule_evidence_from_response", promptID: id, source: "notification",
                                                  detail: "Open proves the request existed. Original scheduling timestamp was not saved; createdAt is used as a proxy."))
                    }
                }
            } catch { message = error.localizedDescription }
            record(.init(date: date, kind: "opened", promptID: id, source: "notification"))
            await reconcile()
        } else {
            choose(promptID: id, exerciseID: action == UNNotificationDismissActionIdentifier ? nil : action, source: "notification", at: date)
        }
    }

    func startExercise(_ promptID: UUID) {
        guard let prompt = activePrompt, prompt.id == promptID,
              let exercise = prompt.options.first(where: { $0.id == prompt.selectedExerciseID })?.exercise else { return }
        var session = prompt.exerciseSession ?? ExerciseSession()
        guard session.runningSince == nil, session.endedAt == nil else { return }
        let now = Date()
        let resuming = session.startedAt != nil
        session.start(at: now)
        guard saveSession(session, promptID: promptID, kind: resuming ? "exercise_resumed" : "exercise_started") else { return }
        WKInterfaceDevice.current().play(.start)
        if let deadline = session.deadline(for: exercise) {
            exerciseEvidence.start(until: deadline)
            Task {
                do {
                    try await notifications.scheduleExerciseEnd(promptID: promptID, exercise: exercise, at: deadline)
                    if activePrompt?.id != promptID || activePrompt?.exerciseSession?.runningSince != now {
                        notifications.removeExerciseEnd(promptID)
                    }
                } catch {
                    record(.init(date: Date(), kind: "exercise_alert_unavailable", promptID: promptID, source: "timer", detail: error.localizedDescription))
                }
            }
        }
    }

    func pauseExercise(_ promptID: UUID) async {
        await tickExercise()
        guard let prompt = activePrompt, prompt.id == promptID, var session = prompt.exerciseSession,
              session.runningSince != nil, session.endedAt == nil else { return }
        session.pause(at: Date())
        let wrist = exerciseEvidence.stop()
        session.wristMovementSeconds += wrist.movement
        session.wristObservedSeconds += wrist.observed
        if saveSession(session, promptID: promptID, kind: "exercise_paused") {
            notifications.removeExerciseEnd(promptID)
        }
    }

    private func saveSession(_ session: ExerciseSession, promptID: UUID, kind: String) -> Bool {
        do {
            try mutate { state in
                guard let index = state.prompts.firstIndex(where: { $0.id == promptID }) else { throw StudyStoreError.invalidResponse }
                state.prompts[index].exerciseSession = session
                state.events.append(.init(date: Date(), kind: kind, promptID: promptID,
                    exerciseID: state.prompts[index].selectedExerciseID, source: "timer"))
            }
            return true
        } catch { message = error.localizedDescription; return false }
    }

    func tickExercise() async {
        guard !assessingExercise, let prompt = activePrompt,
              let exercise = prompt.options.first(where: { $0.id == prompt.selectedExerciseID })?.exercise,
              var session = prompt.exerciseSession else { return }
        if session.endIfDue(for: exercise, at: Date()) {
            let wrist = exerciseEvidence.stop()
            session.wristMovementSeconds += wrist.movement
            session.wristObservedSeconds += wrist.observed
            guard saveSession(session, promptID: prompt.id, kind: "exercise_timer_ended") else { return }
            notifications.removeExerciseEnd(prompt.id)
            WKInterfaceDevice.current().play(.success)
        }
        guard session.endedAt != nil else {
            if let deadline = session.deadline(for: exercise) { exerciseEvidence.start(until: deadline) }
            return
        }
        guard session.assessment == nil else { return }
        assessingExercise = true
        defer { assessingExercise = false }
        let evidence = await exerciseEvidence.evidence(for: session)
        guard activePrompt?.id == prompt.id else { return }
        session.assessment = .evaluate(exercise: exercise, evidence: evidence)
        _ = saveSession(session, promptID: prompt.id, kind: "exercise_movement_assessed")
    }

    func finish(_ prompt: ExercisePrompt, completed: Bool) {
        defer { publishComplications(); scheduleRefresh() }
        do {
            guard let store else { return }
            let now = Date()
            var session = state.prompts.first(where: { $0.id == prompt.id })?.exerciseSession
            let wrist = exerciseEvidence.stop()
            if session != nil {
                session?.pause(at: now)
                session?.wristMovementSeconds += wrist.movement
                session?.wristObservedSeconds += wrist.observed
            }
            try store.finish(promptID: prompt.id, completed: completed, at: now, session: session)
            notifications.removeExerciseEnd(prompt.id)
            requestedPromptID = nil
            navigationRequest = UUID()
            revision += 1
            exportURLs = []
        } catch { message = error.localizedDescription }
    }

    func prepareExport() {
        do {
            record(.init(date: Date(), kind: "export_prepared", source: "app", detail: "Local files prepared; this does not mean they were shared."))
            exportURLs = try store?.export(to: FileManager.default.temporaryDirectory.appendingPathComponent("StudyExport")) ?? []
        } catch { message = "Export failed: \(error.localizedDescription)" }
    }

    private func setPendingRefresh(_ request: RefreshRequest?) {
        pendingRefresh = request
        if let request, let data = try? JSONEncoder().encode(request) {
            UserDefaults.standard.set(data, forKey: "pendingBackgroundRefresh")
        } else {
            UserDefaults.standard.removeObject(forKey: "pendingBackgroundRefresh")
        }
    }

    func scheduleRefresh(recover: Bool = false) {
        let now = Date()
        guard dataAvailable, let plan = BackgroundRefreshPolicy.plan(at: now, settings: settings, context: context, prompts: state.prompts) else { return }
        let request: RefreshRequest
        let previous = pendingRefresh
        let canRecover = recover && (lastRefreshSubmission.map { now.timeIntervalSince($0) >= 60 } ?? true)
        if canRecover, let pendingRefresh {
            request = BackgroundRefreshPolicy.recoveredRequest(pendingRefresh, plan: plan, at: now)
        } else {
            guard BackgroundRefreshPolicy.shouldReplace(pendingRefresh, with: plan, at: now) else { return }
            request = .init(requestedAt: now, preferredDate: plan.date, reason: plan.reason)
        }
        lastRefreshSubmission = now
        setPendingRefresh(request)
        var metadata = ["requestID": request.id.uuidString,
                        "preferredDate": request.preferredDate.ISO8601Format(),
                        "reason": request.reason, "schedulerVersion": BackgroundRefreshPolicy.version]
        if let previous, previous.id != request.id, previous.preferredDate <= now {
            metadata["replacesOverdueRequestID"] = previous.id.uuidString
            metadata["overdueSeconds"] = String(now.timeIntervalSince(previous.preferredDate))
        }
        record(.init(date: now, kind: canRecover ? "background_refresh_rearmed" : "background_refresh_requested", source: "scheduler", attributes: metadata))
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: request.preferredDate, userInfo: metadata as NSDictionary) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    if self.pendingRefresh?.id == request.id { self.setPendingRefresh(nil) }
                    self.record(.init(date: Date(), kind: "background_refresh_failed", source: "scheduler", detail: error.localizedDescription, attributes: metadata))
                } else {
                    self.record(.init(date: Date(), kind: "background_refresh_accepted", source: "scheduler",
                                      detail: "Accepted for scheduling, not an execution guarantee.", attributes: metadata))
                }
            }
        }
    }

    func backgroundRefresh(userInfo: (any NSSecureCoding)?) async {
        let started = Date()
        var attributes = userInfo as? [String: String] ?? [:]
        if let value = attributes["preferredDate"], let date = try? Date.ISO8601FormatStyle().parse(value) {
            attributes["delaySeconds"] = String(started.timeIntervalSince(date))
        }
        let consumed = BackgroundRefreshPolicy.consumes(pendingRefresh, callbackID: attributes["requestID"], at: started)
        attributes["pendingRequestConsumed"] = String(consumed)
        attributes["metadataPresent"] = String(!attributes.isEmpty && attributes["requestID"] != nil)
        if consumed { setPendingRefresh(nil) }
        record(.init(date: started, kind: "background_refresh_started", source: "watchOS", attributes: attributes))
        scheduleRefresh()
        await evaluate(source: "background_refresh", attributes: attributes)
        guard !Task.isCancelled else { return }
        record(.init(date: Date(), kind: "background_refresh_completed", source: "watchOS", attributes: ["durationSeconds": String(Date().timeIntervalSince(started))]))
    }

    private func publishComplications() {
        let now = Date()
        let invitation = currentPrompt ?? state.prompts.first { $0.status == .scheduled && ($0.plannedFor.map { $0 > now } ?? false) }
        var snapshot = ComplicationSnapshot(generatedAt: now, monitoring: settings.monitoring, dataAvailable: dataAvailable,
                                           checkedAt: context?.date, statusDetail: decision?.reasons.first ?? "Waiting for activity signals",
                                           lowMovementMinutes: context?.inactivityEstimate,
                                           inactivityTarget: context.map { ReminderPlanning.inactivityTarget(settings: settings, context: $0, history: state.prompts) } ?? settings.inactivityMinutes,
                                           steps: context?.stepsToday, exerciseMinutes: context?.exerciseMinutes,
                                           completedToday: state.prompts.filter { $0.completedAt.map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false }.count,
                                           invitationExpiresAt: invitation?.expiresAt, invitationStartsAt: invitation?.plannedFor)
        let weekStart = Calendar.current.date(byAdding: .day, value: -7, to: now) ?? now
        snapshot.effortCompletions = state.prompts.compactMap { prompt in
            guard let date = prompt.completedAt, date > weekStart, date <= now,
                  let exercise = prompt.options.first(where: { $0.id == prompt.selectedExerciseID })?.exercise else { return nil }
            return .init(date: date, effort: exercise.effort.rawValue)
        }
        if let activePrompt {
            snapshot.activeExerciseTitle = activePrompt.options.first { $0.id == activePrompt.selectedExerciseID }?.exercise.title
        }
        do {
            guard let url = ComplicationCache.url else {
                throw NSError(domain: "Complications", code: 1, userInfo: [NSLocalizedDescriptionKey: "Shared App Group container is unavailable. Check both targets' signing and App Groups capability."])
            }
            try ComplicationCache.write(snapshot, to: url)
            WidgetCenter.shared.reloadAllTimelines()
            lastComplicationError = nil
            record(.init(date: now, kind: "complication_snapshot_published", source: "widgetkit",
                         detail: "Snapshot saved and reload requested; widget rendering is controlled by watchOS."))
        } catch {
            if lastComplicationError != error.localizedDescription {
                lastComplicationError = error.localizedDescription
                record(.init(date: now, kind: "complication_cache_error", source: "widgetkit", detail: error.localizedDescription))
            }
        }
    }

    private func inspectComplicationConfigurations() async {
        do {
            let configurations = try await WidgetCenter.shared.currentConfigurations()
            let descriptions = configurations.filter { ComplicationKind(rawValue: $0.kind) != nil }
                .map { "\($0.kind):\($0.family)" }.sorted()
            record(.init(date: Date(), kind: "complication_configurations_observed", source: "widgetkit",
                         detail: "Configured widgets are not proof that one is on the currently active face.",
                         attributes: ["configurations": descriptions.joined(separator: ","), "count": String(descriptions.count)]))
        } catch {
            record(.init(date: Date(), kind: "complication_configurations_error", source: "widgetkit", detail: error.localizedDescription))
        }
    }

    func complicationOpened(_ kind: ComplicationKind) {
        record(.init(date: Date(), kind: "complication_opened", source: "widgetkit", attributes: ["kind": kind.rawValue]))
    }
}

@MainActor
final class AppDelegate: NSObject, WKApplicationDelegate {
    func applicationDidFinishLaunching() { _ = AppModel.shared }
    func applicationDidEnterBackground() { AppModel.shared.enteredBackground() }

    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let refresh = task as? WKApplicationRefreshBackgroundTask {
                BackgroundRefreshExecution(refresh).start()
            } else if let snapshot = task as? WKSnapshotRefreshBackgroundTask {
                snapshot.setTaskCompleted(restoredDefaultState: true, estimatedSnapshotExpiration: .distantFuture, userInfo: nil)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}

// Retain each OS task through asynchronous work and complete it exactly once, including expiration.
@MainActor
private final class BackgroundRefreshExecution {
    private let refresh: WKApplicationRefreshBackgroundTask
    private var work: Task<Void, Never>?
    private var finished = false
    private var deadline: Task<Void, Never>?

    init(_ refresh: WKApplicationRefreshBackgroundTask) { self.refresh = refresh }

    func start() {
        refresh.expirationHandler = { [self] in
            Task { @MainActor in
                guard !finished else { return }
                work?.cancel()
                AppModel.shared.backgroundExpired()
                finish()
            }
        }
        deadline = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(8)) } catch { return }
            guard !finished else { return }
            work?.cancel()
            finish()
            AppModel.shared.backgroundExpired(reason: "app_8_second_deadline")
        }
        work = Task { @MainActor in
            await AppModel.shared.backgroundRefresh(userInfo: refresh.userInfo)
            finish()
        }
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        deadline = nil
        refresh.expirationHandler = nil
        refresh.setTaskCompletedWithSnapshot(false)
        work = nil
    }
}
