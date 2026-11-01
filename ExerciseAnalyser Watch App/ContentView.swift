import SwiftUI
import EventKit

private struct WatchLoadingScreen: View {
    let title: String

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            ProgressView(title)
                .progressViewStyle(.circular)
                .tint(.white)
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private extension View {
    func blockingProgress(_ title: String?) -> some View {
        self
            .disabled(title != nil)
            .accessibilityHidden(title != nil)
            .overlay {
                if let title { WatchLoadingScreen(title: title) }
            }
    }
}

private extension Effort {
    var color: Color {
        switch self {
        case .easy: MovementPalette.low
        case .moderate: MovementPalette.moderate
        case .challenge: MovementPalette.high
        }
    }
}

private enum WatchDestination: Hashable {
    case settings, permissions, signals, log, more, manualInvitation, invitation(UUID), exercise(UUID)
}

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = AppModel.shared
    @State private var path: [WatchDestination] = []
    @State private var dashboardPage = 0
    @State private var leavingInvitation: UUID?
    @State private var manualPromptID: UUID?

    init() {}

    fileprivate init(model: AppModel, destination: WatchDestination? = nil) {
        _model = State(initialValue: model)
        _path = State(initialValue: destination.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            dashboard
                .navigationDestination(for: WatchDestination.self) { destination in
                    switch destination {
                    case .settings: SettingsView(model: model)
                    case .permissions: PermissionsView(model: model)
                    case .signals: SignalsView(model: model)
                    case .log: StudyView(model: model)
                    case .more: more
                    case .manualInvitation: manualInvitation
                    case .invitation(let id): invitation(id)
                    case .exercise(let id): ExerciseSessionView(model: model, promptID: id) {
                        path = [.invitation(id)]
                    }
                    }
                }
        }
        .blockingProgress(model.loadingData ? "Loading…" : (model.savingData > 0 ? "Saving…" : nil))
        .defaultAppStorage(model.isPreview ? UserDefaults(suiteName: "MoveMoment.WatchPreviews")! : .standard)
        .onOpenURL { url in
            guard let kind = ComplicationKind.allCases.first(where: { $0.url == url }) else { return }
            model.complicationOpened(kind)
            if kind == .missed {
                path = []
                dashboardPage = 2
            } else {
                routeCurrentOptions()
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && !model.isPreview {
                model.expireInvitations()
                clearExpiredDestination()
                // Wrist-down/wake also activates the scene. Keep the current timer or other valid screen.
                if path.isEmpty { routeCurrentOptions() }
            }
        }
        .onChange(of: model.navigationRequest) { routeRequestedPrompt() }
        .onChange(of: model.revision) { clearExpiredDestination() }
        .task {
            guard !model.isPreview else { return }
            clearExpiredDestination()
            if path.isEmpty { routeCurrentOptions() }
            while !Task.isCancelled {
                await model.tickExercise()
                model.expireInvitations()
                clearExpiredDestination()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .alert("Move Moment", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
        .alert("Ignore this movement break?", isPresented: Binding(get: { leavingInvitation != nil }, set: { if !$0 { leavingInvitation = nil } })) {
            if let id = leavingInvitation {
                Button("Ignore break", role: .destructive) {
                    Task { if await model.leaveInvitation(id) { path = [] } }
                    leavingInvitation = nil
                }
            }
            Button("Stay", role: .cancel) { leavingInvitation = nil }
        } message: {
            Text("Leave this invitation? It will count as a missed break.")
        }
    }

    private func clearExpiredDestination() {
        guard let destination = path.last else { return }
        let id: UUID
        switch destination {
        case .invitation(let promptID), .exercise(let promptID): id = promptID
        case .manualInvitation:
            guard let promptID = manualPromptID else { return }
            id = promptID
        default: return
        }
        guard let prompt = model.state.prompts.first(where: { $0.id == id }),
              prompt.isAvailable(at: Date()) || prompt.isActive(at: Date()) else {
            leavingInvitation = nil
            path = []
            return
        }
    }

    private func routeCurrentOptions() {
        model.expireInvitations()
        leavingInvitation = nil
        // Fresh entry starts at effort selection; scene wake preserves the existing navigation path.
        if let prompt = model.activePrompt { path = [.invitation(prompt.id)] }
        else if let prompt = model.currentPrompt { path = [.invitation(prompt.id)] }
        else { path = [] }
    }

    private func routeRequestedPrompt() {
        guard let id = model.requestedPromptID,
              let prompt = model.state.prompts.first(where: { $0.id == id }),
              prompt.isAvailable(at: Date()) || prompt.isActive(at: Date()) else { path = []; return }
        if prompt.status == .selected && !model.requestedEffortSelection { path = [.invitation(id), .exercise(id)] }
        else { path = [.invitation(id)] }
    }

    private func openCurrentBreak() {
        if let prompt = model.activePrompt { path = [.invitation(prompt.id), .exercise(prompt.id)] }
        else if let prompt = model.currentPrompt { path.append(.invitation(prompt.id)) }
        else { path.append(.more) }
    }

    private var todayContext: ContextSnapshot? {
        guard let context = model.context, Calendar.current.isDateInToday(context.date) else { return nil }
        return context
    }

    private var dashboard: some View {
        TabView(selection: $dashboardPage) {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                statusCard(at: timeline.date)
            }
            .tag(0)
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                weeklyCard(at: timeline.date)
            }
            .tag(1)
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                missedCard(at: timeline.date)
            }
            .tag(2)
            metricCard("Steps", value: todayContext?.stepsToday, unit: "steps today", symbol: "shoeprints.fill", color: MovementPalette.steps)
                .tag(3)
            metricCard("Heart rate", value: model.context?.heartRate?.value, unit: "bpm · latest", symbol: "heart.fill", color: .red,
                       sampledAt: model.context?.heartRate?.date)
                .tag(4)
        }
        .tabViewStyle(.verticalPage)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Settings", systemImage: "slider.horizontal.3") { path.append(.settings) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("More", systemImage: "ellipsis") { path.append(.more) }
            }
        }
    }

    private func weeklyCard(at date: Date) -> some View {
        let days = model.summaryDays(at: date)
        let today = days.last { Calendar.current.isDate($0.date, inSameDayAs: date) }
        let color = MovementPalette.effort(today?.selections?.dominant)
        let maximum = max(days.map(\.completed).max() ?? 0, 1)
        return ScrollView(.vertical) {
            VStack(spacing: 14) {
                Label("This week", systemImage: "calendar")
                    .font(.headline).foregroundStyle(color)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 10)
                if model.dataAvailable {
                    ForEach(days.reversed()) { day in
                        HStack(spacing: 8) {
                            Text(Calendar.current.isDate(day.date, inSameDayAs: date) ? "Today" : day.date.formatted(.dateTime.weekday(.abbreviated)))
                                .font(.caption.weight(.medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                                .frame(width: 48, alignment: .leading)
                            GeometryReader { geometry in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(.white.opacity(0.1))
                                    if day.completed > 0 {
                                        Capsule()
                                            .fill(LinearGradient(gradient: MovementPalette.completionGradient(day), startPoint: .leading, endPoint: .trailing))
                                            .frame(width: max(4, geometry.size.width * Double(day.completed) / Double(maximum)))
                                    }
                                }
                            }
                            .frame(height: 8)
                            Text(day.completed.formatted())
                                .font(.caption.monospacedDigit())
                                .frame(minWidth: 20, alignment: .trailing)
                        }
                        .frame(minHeight: 24)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(day.date.formatted(.dateTime.weekday(.wide))): \(day.completed) completed breaks, \(day.low) low, \(day.moderate) moderate, \(day.high) high effort")
                    }
                    Text("\(days.reduce(0) { $0 + $1.completed }) completed breaks")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Study data unavailable").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .containerBackground(for: .tabView) { tabGlow(color) }
    }

    private func missedCard(at date: Date) -> some View {
        let missed = CompanionSummary.missedCount(in: model.state.prompts, on: date, asOf: date, calendar: .current)
        return VStack(spacing: 2) {
            Label("Missed breaks", systemImage: "clock.badge.xmark")
                .font(.headline).foregroundStyle(MovementPalette.missed)
            Text(model.dataAvailable ? missed.formatted() : "—")
                .font(.system(size: 54, weight: .semibold, design: .rounded))
                .monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                .contentTransition(.numericText())
            Text(model.dataAvailable ? "missed today" : "No data yet")
                .font(.callout).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .containerBackground(for: .tabView) { tabGlow(MovementPalette.missed) }
        .accessibilityElement(children: .combine)
    }

    private var missingPermissions: [String] {
        var missing: [String] = []
        if !model.healthConfigured { missing.append("Health") }
        if !model.calendarAccess { missing.append("Calendar") }
        if !model.motionAccess { missing.append("Motion") }
        if !model.notificationAccess { missing.append("Notifications") }
        return missing
    }

    private func statusCard(at date: Date) -> some View {
        let status = monitoringStatus(at: date)
        return VStack(spacing: 8) {
            Image(systemName: status.symbol)
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(status.color)
                .accessibilityHidden(true)
            Text(status.title)
                .font(.title3.bold())
                .foregroundStyle(status.color)
            Text(status.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
        .containerBackground(for: .tabView) { tabGlow(status.color) }
        .accessibilityElement(children: .combine)
    }

    private func tabGlow(_ color: Color) -> some View {
        RadialGradient(
            stops: [
                .init(color: color.opacity(0.3), location: 0),
                .init(color: color.opacity(0.1), location: 0.45),
                .init(color: .clear, location: 1)
            ],
            center: .top,
            startRadius: 0,
            endRadius: 150
        )
        .background(.black)
    }

    private func monitoringStatus(at date: Date) -> (title: String, detail: String, symbol: String, color: Color) {
        if !model.dataAvailable {
            return ("Monitoring unavailable", "Study data could not be opened.", "exclamationmark.triangle.fill", .yellow)
        }
        if model.refreshingAccess {
            return ("Checking access", "Checking your permissions…", "ellipsis.circle", .secondary)
        }
        if !missingPermissions.isEmpty {
            return ("Permissions needed", "Enable \(missingPermissions.joined(separator: ", ")) in Settings → Permissions.", "exclamationmark.triangle.fill", .yellow)
        }
        if !model.settings.monitoring {
            return ("Monitoring paused", "Enable monitoring in Settings.", "pause.circle.fill", .secondary)
        }
        if !ReminderPlanning.active(at: date, settings: model.settings, calendar: .current) {
            return ("Winding down", "Reminders are resting outside your alert hours.", "bed.double.fill", .purple)
        }
        return ("Monitoring", "Looking for a good moment to move.", "checkmark.circle.fill", .mint)
    }

    private func metricCard(_ title: String, value: Double?, unit: String, symbol: String, color: Color,
                            decimals: Int = 0, sampledAt: Date? = nil) -> some View {
        VStack(spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.headline).foregroundStyle(color)
            Text(value.map { $0.formatted(.number.precision(.fractionLength(decimals))) } ?? "—")
                .font(.system(size: 54, weight: .semibold, design: .rounded))
                .monospacedDigit().minimumScaleFactor(0.5).lineLimit(1)
                .contentTransition(.numericText())
            Text(value == nil ? "No data yet" : unit).font(.callout).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            Group {
                if let date = sampledAt ?? model.context?.date {
                    Text("Updated \(date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened))")
                } else {
                    Text(model.checking ? "Reading signals…" : "Connect in Settings")
                }
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.bottom, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .padding(.horizontal, 24)
        .containerBackground(for: .tabView) { tabGlow(color) }
        .accessibilityElement(children: .combine)
    }

    private var more: some View {
        List {
            NavigationLink("Take a break", value: WatchDestination.manualInvitation)
                .disabled(!model.dataAvailable)
            NavigationLink("Research", value: WatchDestination.log)
            NavigationLink("Watch activity", value: WatchDestination.signals)
        }.navigationTitle("More")
    }

    @ViewBuilder
    private var manualInvitation: some View {
        Group {
            if let id = manualPromptID {
                invitation(id)
            } else {
                WatchLoadingScreen(title: "Preparing your break…")
            }
        }
        .task {
            guard manualPromptID == nil else { return }
            let id = await model.triggerManualIntervention()
            guard !Task.isCancelled else { return }
            if let id {
                manualPromptID = id
                if model.activePrompt?.id == id {
                    withAnimation { path.append(.exercise(id)) }
                }
            } else if path.last == .manualInvitation {
                withAnimation { _ = path.removeLast() }
            }
        }
        .onDisappear { manualPromptID = nil }
    }

    @ViewBuilder
    private func invitation(_ id: UUID) -> some View {
        if let prompt = model.state.prompts.first(where: { $0.id == id }), (prompt.isAvailable(at: Date()) || prompt.isActive(at: Date())) {
            List {
                Section("Choose a break") {
                    ForEach(prompt.options) { option in
                        Button { model.choose(promptID: prompt.id, exerciseID: option.id) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: option.exercise.symbol).font(.title3).foregroundStyle(option.exercise.effort.color)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(option.exercise.title).font(.headline)
                                    Text("\(option.exercise.minutes) min · \(option.exercise.effort.title)")
                                        .font(.caption).foregroundStyle(option.exercise.effort.color)
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }.navigationTitle("")
                .navigationBarBackButtonHidden()
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.left") {
                            if prompt.isManual {
                                Task { if await model.leaveInvitation(id) { path = [] } }
                            } else { leavingInvitation = id }
                        }
                        .labelStyle(.iconOnly)
                    }
                }
        } else {
            ContentUnavailableView("Break unavailable", systemImage: "clock", description: Text("This invitation has ended. A new opportunity will appear on your home screen."))
        }
    }
}

private struct ExerciseSessionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @Environment(\.scenePhase) private var scenePhase
    let model: AppModel
    let promptID: UUID
    let onBack: () -> Void
    @State private var showingInfo = false
    @State private var confirmingBack = false
    @State private var showingDisplayTip = false
    @AppStorage("hasSeenReturnToClockTip") private var hasSeenDisplayTip = false

    init(model: AppModel, promptID: UUID, showingInfo: Bool = false, showingDisplayTip: Bool = false, onBack: @escaping () -> Void) {
        self.model = model
        self.promptID = promptID
        self.onBack = onBack
        _showingInfo = State(initialValue: showingInfo)
        _showingDisplayTip = State(initialValue: showingDisplayTip)
    }

    private var prompt: ExercisePrompt? { model.state.prompts.first { $0.id == promptID } }

    var body: some View {
        Group {
            if let prompt, let exercise = prompt.options.first(where: { $0.id == prompt.selectedExerciseID })?.exercise {
                let session = prompt.exerciseSession ?? ExerciseSession()
                if prompt.completedAt != nil || prompt.abandonedAt != nil {
                    ContentUnavailableView("Break saved", systemImage: "checkmark.circle", description: Text("You can find this break in Research."))
                } else {
                    Group {
                        if session.endedAt != nil { completion(session) }
                        else { timer(exercise: exercise, session: session) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .containerBackground(exercise.effort.color.opacity(0.1).gradient, for: .navigation)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Back", systemImage: "chevron.left") {
                                if session.startedAt != nil { confirmingBack = true }
                                else { onBack() }
                            }
                            .labelStyle(.iconOnly)
                        }
                        ToolbarItemGroup(placement: .bottomBar) {
                            Spacer()
                            if session.endedAt != nil {
                                Button("I did it", systemImage: "checkmark") { model.finish(prompt, completed: true) }
                                    .labelStyle(.iconOnly)
                                    .disabled(session.assessment == nil)
                            } else {
                                Button {
                                    if session.runningSince == nil {
                                        if !hasSeenDisplayTip { showingDisplayTip = true }
                                        else { model.startExercise(prompt.id) }
                                    } else { Task { await model.pauseExercise(prompt.id) } }
                                } label: {
                                    Label(session.runningSince != nil ? "Pause exercise" : (session.startedAt == nil ? "Start exercise" : "Resume exercise"),
                                          systemImage: session.runningSince == nil ? "play.fill" : "pause.fill")
                                }
                                .labelStyle(.iconOnly)
                            }
                            Spacer()
                        }
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Exercise information", systemImage: "info") {
                                Task {
                                    if session.runningSince != nil { await model.pauseExercise(prompt.id) }
                                    showingInfo = true
                                }
                            }
                            .labelStyle(.iconOnly)
                        }
                    }
                    .sheet(isPresented: $showingDisplayTip) {
                        NavigationStack {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 16) {
                                    TimerDisplayGuidance()
                                    Button("Start exercise") {
                                        hasSeenDisplayTip = true
                                        showingDisplayTip = false
                                        model.startExercise(prompt.id)
                                    }
                                    .buttonStyle(.glass)
                                    Button("Not now", role: .cancel) { showingDisplayTip = false }
                                }.padding()
                            }.navigationTitle("Before you start")
                        }
                    }
                    .sheet(isPresented: $showingInfo) {
                        NavigationStack {
                            List {
                                Section(exercise.title) {
                                    Text("\(exercise.minutes) min · \(exercise.effort.title)").foregroundStyle(exercise.effort.color)
                                    Text(exercise.instructions)
                                }
                                Section("Keep the timer visible") { TimerDisplayGuidance() }
                                Section("Movement check") {
                                    Text(exercise.measurementHint)
                                    Text(session.assessment?.explanation ?? "Your Watch estimates movement. If it can’t get a reading, you can still tell us you did it.")
                                    Text("This timer doesn’t save a workout to Health. Movement readings may pause when you leave the app.").foregroundStyle(.secondary)
                                }
                                Text("Move within your comfort. Stop if you feel pain, dizziness, or unwell.").foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done", systemImage: "checkmark") { showingInfo = false }.labelStyle(.iconOnly) } }
                        }
                    }
                    .alert("Go back to effort selection?", isPresented: $confirmingBack) {
                        Button("Go back", role: .destructive) {
                            Task {
                                if session.runningSince != nil { await model.pauseExercise(prompt.id) }
                                onBack()
                            }
                        }
                        Button("Stay", role: .cancel) { }
                    } message: {
                        Text("Your timer will stay paused. Choosing a different exercise will reset it.")
                    }
                }
            } else {
                ContentUnavailableView("No exercise selected", systemImage: "figure.walk")
            }
        }
        .navigationTitle("")
        .navigationBarBackButtonHidden()
    }

    private func timer(exercise: Exercise, session: ExerciseSession) -> some View {
        VStack(spacing: 4) {
            Text(exercise.title).font(.headline).lineLimit(2).minimumScaleFactor(0.85)
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let remaining = session.remaining(for: exercise, at: timeline.date)
                let animateDigits = !reduceMotion && !isLuminanceReduced && scenePhase == .active
                    && timeline.cadence == .live && session.runningSince != nil
                Text("\(remaining / 60):\(String(format: "%02d", remaining % 60))")
                    .font(.system(size: 58, weight: .medium, design: .rounded))
                    .monospacedDigit().foregroundStyle(exercise.effort.color)
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .contentTransition(animateDigits ? .numericText(countsDown: true) : .identity)
                    .animation(animateDigits ? .easeInOut(duration: 0.3) : nil, value: remaining)
                    // Discard an in-flight digit transition when Always On reduces rendering.
                    .id(animateDigits)
                    .transaction { transaction in
                        if !animateDigits {
                            transaction.animation = nil
                            transaction.disablesAnimations = true
                        }
                    }
                    .accessibilityLabel("\(remaining / 60) minutes and \(remaining % 60) seconds remaining")
            }
            Text(session.runningSince != nil ? "Keep moving" : (session.startedAt == nil ? "Press play to begin" : "Paused"))
                .font(.callout).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
    }

    private func completion(_ session: ExerciseSession) -> some View {
        VStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").font(.largeTitle).foregroundStyle(.mint)
                .symbolEffect(.bounce, value: session.endedAt)
                .accessibilityLabel("Timer complete")
            Text("Nice work!").font(.title2.bold())
            if let assessment = session.assessment {
                Text(assessment.outcome == .movementDetected ? "Movement detected" : (assessment.outcome == .littleMovement ? "Little movement" : "Unable to verify"))
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Checking movement…").font(.caption).foregroundStyle(.secondary)
            }
            Text("Did you do it?").font(.caption2).foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
    }
}

private struct SignalsView: View {
    let model: AppModel

    var body: some View {
        List {
            Section {
                NavigationLink("Background updates") {
                    List {
                        eventTime("Last refresh", kind: "background_refresh_started")
                        if let date = model.nextRefreshDate {
                            Text("Next refresh requested: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                        } else { Text("No refresh planned yet").font(.caption) }
                        let recent = model.state.events.filter { $0.date >= Date().addingTimeInterval(-86400) }
                        let checks = recent.filter { $0.kind == "opportunity_evaluated" && $0.attributes["applicationState"] == "background" }.count
                        let updates = recent.filter { $0.kind == "health_observer_received" && $0.attributes["applicationState"] == "background" }.count
                        Text("24h: \(checks) background checks · \(updates) Health updates").font(.caption)
                        let expirations = recent.filter { $0.kind == "background_refresh_expired" }.count
                        if expirations > 0 { Text("\(expirations) refreshes ran out of time in 24h").font(.caption).foregroundStyle(.yellow) }
                        if let failure = model.state.events.last(where: { $0.kind == "background_refresh_failed" }) {
                            Text("Last scheduling error: \(failure.detail ?? "Unknown")").font(.caption).foregroundStyle(.yellow)
                            Text(failure.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2)
                        }
                        Text("Your Watch decides when it can refresh in the background, so updates may arrive later.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }.navigationTitle("Background updates")
                }
            }
            if let context = model.context {
                Section("Latest check") {
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                    ForEach(model.decision?.reasons ?? [], id: \.self) { Text($0).font(.caption) }
                }
                Section("Time for a break") {
                    metric("Little movement", context.inactivityEstimate, suffix: "min")
                    Text("Calendar: \(context.calendarAvailable ? (context.busy ? "Busy" : "Free") : "Unknown")")
                    metric("Time available", context.freeMinutes, suffix: "min")
                    Text("Motion: \(context.motion.rawValue)")
                }
                Section("Activity today") {
                    metric("Steps", context.stepsToday)
                    metric("Steps · last 15 min", context.stepsRecent)
                    metric("Exercise", context.exerciseMinutes, suffix: "min")
                    metric("Standing", context.standMinutes, suffix: "min")
                    metric("Active energy", context.activeEnergy, suffix: "kcal")
                    metric("Distance", context.distanceMeters, suffix: "m")
                }
                Section("Rest & recovery") {
                    metric("Heart rate", context.heartRate?.value, suffix: "bpm")
                    if let date = context.heartRate?.date { Text("Recorded: \(date.formatted(date: .omitted, time: .shortened))").font(.footnote) }
                    metric("Resting heart rate", context.restingHeartRate?.value, suffix: "bpm")
                    metric("HRV", context.heartRateVariability?.value, suffix: "ms")
                    metric("HRV baseline", context.hrvBaseline, suffix: "ms")
                    metric("Sleep · last 24h", context.sleepHours, suffix: "h", decimals: 1)
                }
                Section("Watch") {
                    metric("Battery", context.batteryLevel.map { $0 * 100 }, suffix: "%")
                    Text(context.charging ? "Charging" : "Not charging")
                    Text(context.lowPower ? "Low Power Mode on" : "Low Power Mode off")
                }
                if !context.issues.isEmpty {
                    Section("Readings to check") { ForEach(context.issues, id: \.self) { Text($0).font(.caption) } }
                }
            } else { Text("Turn on movement reminders in Settings to see your readings here.") }
            Text("Missing readings don’t mean zero activity. Check your permissions if a reading stays unavailable.")
                .font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("Watch activity")
    }

    private func eventTime(_ title: String, kind: String) -> some View {
        Text("\(title): \(model.state.events.last(where: { $0.kind == kind }).map { $0.date.formatted(date: .abbreviated, time: .shortened) } ?? "None recorded")")
            .font(.caption)
    }

    private func metric(_ title: String, _ value: Double?, suffix: String = "", decimals: Int = 0) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { String(format: "%.*f", decimals, $0) + (suffix.isEmpty ? "" : " \(suffix)") } ?? "Unknown")
        }
    }
}

private struct TimerDisplayGuidance: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Keep your timer on screen", systemImage: "applewatch").font(.headline)
            Text(MovementCopy.timerIntro)
            Text(MovementCopy.timerPath)
            Text(MovementCopy.timerNote)
                .foregroundStyle(.secondary)
        }.font(.caption)
    }
}

private struct PermissionsView: View {
    let model: AppModel

    var body: some View {
        Form {
            Section("Connect your Watch") {
                Button(model.healthConfigured ? "Health setup complete" : "Connect Health") { Task { await model.requestHealth() } }
                    .disabled(model.healthConfigured)
                Button(model.calendarAccess ? "Calendar allowed" : "Allow Calendar") { Task { await model.requestCalendar() } }
                    .disabled(model.calendarAccess)
                Button(model.motionAccess ? "Motion allowed" : "Allow Motion") { Task { await model.requestMotion() } }
                    .disabled(model.motionAccess)
                Button(model.notificationAccess ? "Notifications enabled" : "Allow notifications") { Task { await model.requestNotifications() } }
                    .disabled(model.notificationAccess)
            }.disabled(model.requestingAccess || model.refreshingAccess)
            Text(MovementCopy.healthNote).font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("Permissions")
            .blockingProgress(model.refreshingAccess ? "Checking access…" : nil)
    }
}

private struct SettingsView: View {
    let model: AppModel

    private func setting<Value>(_ keyPath: WritableKeyPath<Settings, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { value in model.updateSettings { $0[keyPath: keyPath] = value } })
    }

    var body: some View {
        Form {
            Section("Movement reminders") {
                Toggle("Reminders on", isOn: setting(\.monitoring)).disabled(!model.dataAvailable)
                Text("Let your Watch look for a good moment to take a break.").font(.footnote)
            }
            Section {
                NavigationLink("Permissions", value: WatchDestination.permissions)
                NavigationLink("Calendars") { CalendarSelectionView(model: model) }
            }
            Section {
                NavigationLink("Keep your timer on screen") {
                    ScrollView { TimerDisplayGuidance().padding() }
                        .navigationTitle("Timer display")
                }
            }
            Section("Reminder rhythm") {
                Picker("After little movement", selection: setting(\.inactivityMinutes)) {
                    ForEach([15, 30, 45, 60, 90], id: \.self) { Text("\($0) min").tag($0) }
                }
                Picker("Time between reminders", selection: setting(\.cooldownMinutes)) {
                    ForEach([30, 45, 60, 90, 120, 180], id: \.self) { Text($0 == 0 ? "No wait" : "\($0) min").tag($0) }
                }
                VStack(alignment: .leading) {
                    Text("Daily limit")
                    HStack {
                        Button {
                            model.updateSettings {
                                $0.dailyLimit = $0.dailyLimit == Settings.unlimitedDailyLimit ? 10 : max(1, $0.dailyLimit - 1)
                            }
                        } label: {
                            Image(systemName: "minus").frame(minWidth: 32, minHeight: 44)
                        }
                        .disabled(model.settings.dailyLimit == 1)
                        .accessibilityLabel("Decrease daily reminder limit")
                        Text(model.settings.dailyLimit == Settings.unlimitedDailyLimit ? "Unlimited" : "\(model.settings.dailyLimit) / day")
                            .frame(maxWidth: .infinity)
                            .minimumScaleFactor(0.8)
                            .lineLimit(1)
                        Button {
                            model.updateSettings {
                                $0.dailyLimit = $0.dailyLimit >= 10 ? Settings.unlimitedDailyLimit : $0.dailyLimit + 1
                            }
                        } label: {
                            Image(systemName: "plus").frame(minWidth: 32, minHeight: 44)
                        }
                        .disabled(model.settings.dailyLimit == Settings.unlimitedDailyLimit)
                        .accessibilityLabel("Increase daily reminder limit")
                    }
                    .buttonStyle(.borderless)
                }
                Text(MovementCopy.reminderTiming).font(.footnote)
                AlarmTimeSetting(title: "From", hour: model.settings.startHour, minute: model.settings.startMinute) { hour, minute in
                    model.updateSettings {
                        $0.startHour = hour
                        $0.startMinute = minute
                    }
                }
                AlarmTimeSetting(title: "Until", hour: model.settings.endHour, minute: model.settings.endMinute) { hour, minute in
                    model.updateSettings {
                        $0.endHour = hour
                        $0.endMinute = minute
                    }
                }
                Text(MovementCopy.calendarNote).font(.footnote)
            }
            Section("Your exercises") {
                Picker("Surprise choices", selection: setting(\.explorationRate)) {
                    ForEach([0.0, 0.1, 0.3, 0.5, 1.0], id: \.self) { Text("\(Int($0 * 100))%").tag($0) }
                }
                Text("Reminders adapt to your routine and give you more space when you miss a few.").font(.footnote)
                Text(MovementCopy.suggestionNote).font(.footnote)
                NavigationLink("Choose your exercises") {
                    ExerciseSelectionView(model: model)
                }
            }
            Section("Your data") {
                NavigationLink("Research", value: WatchDestination.log)
                Text(MovementCopy.privacy).font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Settings")
            .task { await model.refreshAccessStatus() }
    }
}

private struct ExerciseSelectionView: View {
    let model: AppModel

    var body: some View {
        Form {
            ForEach(Effort.allCases, id: \.self) { effort in
                Section(effort.title) {
                    ForEach(Exercise.catalog.filter { $0.effort == effort }) { exercise in
                        Toggle(exercise.title, isOn: Binding(get: { !model.settings.excludedExerciseIDs.contains(exercise.id) }, set: { enabled in
                            model.updateSettings {
                                if enabled { $0.excludedExerciseIDs.remove(exercise.id) }
                                else { $0.excludedExerciseIDs.insert(exercise.id) }
                            }
                        }))
                    }
                }
            }
            Text("Keep at least one exercise in each level. Effort is relative; choose movements that suit you.").font(.footnote)
        }.navigationTitle("Exercises")
    }
}

private struct CalendarSelectionView: View {
    let model: AppModel

    var body: some View {
        Form {
            if model.calendarAccess {
                Toggle("All calendars", isOn: Binding(get: { model.settings.selectedCalendarIDs == nil }, set: { enabled in
                    model.updateSettings {
                        $0.selectedCalendarIDs = enabled ? nil : Set(model.availableCalendars.map(\.calendarIdentifier))
                    }
                }))
                Section("Calendars to check") {
                    ForEach(model.availableCalendars, id: \.calendarIdentifier) { calendar in
                        Toggle(isOn: Binding(get: { model.settings.checksCalendar(calendar.calendarIdentifier) }, set: { enabled in
                            model.updateSettings {
                                var selected = $0.selectedCalendarIDs ?? Set(model.availableCalendars.map(\.calendarIdentifier))
                                if enabled { selected.insert(calendar.calendarIdentifier) }
                                else { selected.remove(calendar.calendarIdentifier) }
                                $0.selectedCalendarIDs = selected
                            }
                        })) {
                            VStack(alignment: .leading) {
                                Text(calendar.title)
                                Text(calendar.source.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(model.settings.selectedCalendarIDs == nil)
                    }
                    if model.availableCalendars.isEmpty {
                        Text("No calendars are available on this watch.").font(.footnote)
                    }
                }
                Text(MovementCopy.calendarNote).font(.footnote)
                if !model.availableCalendars.contains(where: { model.settings.checksCalendar($0.calendarIdentifier) }) {
                    Text("No calendars selected. Reminders won’t wait for your events.").font(.footnote)
                }
            } else {
                Button("Enable calendar access") { Task { await model.requestCalendar() } }
                    .disabled(model.requestingAccess)
                Text("Allow calendar access to choose which calendars to check.").font(.footnote)
            }
        }.navigationTitle("Calendars")
            .disabled(!model.dataAvailable)
            .task { await model.refreshAccessStatus() }
    }
}

private struct AlarmTimeSetting: View {
    let title: String
    let hour: Int
    let minute: Int?
    let save: (Int, Int) -> Void
    @State private var editing = false
    @State private var pendingTime: (hour: Int, minute: Int)?

    var body: some View {
        Button {
            editing = true
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%02d:%02d", hour, minute ?? 0))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel("\(title), \(String(format: "%02d:%02d", hour, minute ?? 0))")
        .fullScreenCover(isPresented: $editing, onDismiss: {
            guard let pendingTime else { return }
            self.pendingTime = nil
            if pendingTime.hour != hour || pendingTime.minute != (minute ?? 0) {
                save(pendingTime.hour, pendingTime.minute)
            }
        }) {
            AlarmTimeEditor(title: title, hour: hour, minute: minute ?? 0) { newHour, newMinute in
                pendingTime = (newHour, newMinute)
            }
        }
    }
}

private struct AlarmTimeEditor: View {
    private enum Field: Hashable { case hour, minute }

    let title: String
    let save: (Int, Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var hour: Double
    @State private var minute: Double
    @State private var closing = false
    @FocusState private var focusedField: Field?

    init(title: String, hour: Int, minute: Int, save: @escaping (Int, Int) -> Void) {
        self.title = title
        self.save = save
        _hour = State(initialValue: Double(hour))
        _minute = State(initialValue: Double(minute))
    }

    private var editingMinutes: Bool { focusedField == .minute }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size.width
            let radius = size * 0.46 - 14
            ZStack {
                Color.black
                ZStack {
                    ForEach(0..<60, id: \.self) { tick in
                        Capsule()
                            .fill(tick.isMultiple(of: 5) ? Color.white : Color.gray)
                            .frame(width: tick.isMultiple(of: 5) ? 1.5 : 1, height: tick.isMultiple(of: 5) ? 7 : 4)
                            .offset(y: -radius)
                            .rotationEffect(.degrees(Double(tick) * 6))
                    }
                    ForEach(0..<12, id: \.self) { index in
                        let angle = Double(index) * .pi / 6
                        Text(String(format: "%02d", index * (editingMinutes ? 5 : 2)))
                            .font(.system(size: size * 0.065))
                            .monospacedDigit()
                            .offset(x: sin(angle) * radius * 0.80, y: -cos(angle) * radius * 0.80)
                    }
                    Circle()
                        .fill(.orange)
                        .frame(width: 8, height: 8)
                        .offset(y: -radius)
                        .rotationEffect(.degrees(editingMinutes ? minute * 6 : hour * 15))
                    VStack(spacing: 6) {
                        Text(editingMinutes ? "MIN" : "24HR")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            timeField(value: $hour, field: .hour, maximum: 23, size: size)
                            Text(":").font(.system(size: size * 0.12))
                            timeField(value: $minute, field: .minute, maximum: 59, size: size)
                        }
                    }
                }
                .frame(width: size, height: size)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(title) time")
                VStack {
                    Spacer()
                    HStack {
                        Button {
                            close(saving: false)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 20, weight: .semibold))
                                .frame(width: 40, height: 40)
                                .glassEffect(.regular.interactive(), in: Circle())
                        }
                        .accessibilityLabel("Cancel")
                        Spacer()
                        Button {
                            close(saving: true)
                        } label: {
                            Image(systemName: "checkmark")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 40, height: 40)
                                .glassEffect(.regular.interactive(), in: Circle())
                        }
                        .accessibilityLabel("Save time")
                    }
                    .buttonStyle(.plain)
                    .disabled(closing)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }
        }
        .ignoresSafeArea()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear { focusedField = .hour }
        .onDisappear { focusedField = nil }
    }

    private func close(saving: Bool) {
        guard !closing else { return }
        closing = true
        focusedField = nil
        if saving { save(Int(hour.rounded()), Int(minute.rounded())) }
        // Let SwiftUI release the Crown's focused view before removing the editor.
        Task { @MainActor in
            await Task.yield()
            dismiss()
        }
    }

    private func timeField(value: Binding<Double>, field: Field, maximum: Double, size: CGFloat) -> some View {
        Text(String(format: "%02d", Int(value.wrappedValue.rounded())))
            .font(.system(size: size * 0.14, weight: .medium, design: .rounded))
            .monospacedDigit()
            .frame(width: size * 0.24, height: size * 0.26)
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(focusedField == field ? Color.green : Color.gray, lineWidth: focusedField == field ? 2 : 1)
            }
            .contentShape(Rectangle())
            .focusable(!closing)
            .focused($focusedField, equals: field)
            .digitalCrownRotation(value, from: 0, through: maximum, by: 1, sensitivity: .low, isContinuous: true, isHapticFeedbackEnabled: true)
            .onTapGesture { focusedField = field }
            .accessibilityLabel(field == .hour ? "Hours" : "Minutes")
            .accessibilityValue(String(Int(value.wrappedValue.rounded())))
            .accessibilityAdjustableAction { direction in
                focusedField = field
                switch direction {
                case .increment: value.wrappedValue = value.wrappedValue >= maximum ? 0 : value.wrappedValue + 1
                case .decrement: value.wrappedValue = value.wrappedValue <= 0 ? maximum : value.wrappedValue - 1
                @unknown default: break
                }
            }
    }
}

private struct StudyView: View {
    let model: AppModel

    var body: some View {
        List {
            Section("Your study so far") {
                LabeledContent("Breaks you completed", value: model.state.prompts.filter { $0.completedAt != nil }.count.formatted())
                LabeledContent("Invitations", value: model.state.prompts.count.formatted())
                Text(MovementCopy.completionNote).font(.footnote).foregroundStyle(.secondary)
            }
            Section("Your recent breaks") {
                if model.state.prompts.isEmpty { Text("Your first break will appear here.").foregroundStyle(.secondary) }
                ForEach(Array(model.state.prompts.suffix(20).reversed())) { prompt in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(prompt.options.first { $0.id == prompt.selectedExerciseID }?.exercise.title ?? "Movement invitation")
                            .font(.headline)
                        Text(MovementCopy.outcome(prompt.completedAt != nil ? "Completed" : prompt.abandonedAt != nil ? "Abandoned" : prompt.status.rawValue))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(prompt.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Share with your researcher") {
                Button("Prepare my files") { model.prepareExport() }
                ForEach(model.exportURLs, id: \.self) { url in
                    ShareLink(item: url, preview: SharePreview(url.lastPathComponent)) {
                        Label(exportTitle(url), systemImage: "square.and.arrow.up")
                    }
                }
                Text(MovementCopy.shareNote).font(.footnote).foregroundStyle(.secondary)
            }
            Section("About your data") {
                NavigationLink("Watch activity", value: WatchDestination.signals)
                NavigationLink("Your study ID") {
                    List {
                        Text(model.state.participantID.uuidString).font(.caption.monospaced())
                        Text("Use this ID if your researcher asks you to identify your records.").font(.footnote)
                    }.navigationTitle("Your study ID")
                }
                Text(MovementCopy.privacy).font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Research")
    }

    private func exportTitle(_ url: URL) -> String {
        switch url.pathExtension {
        case "csv": "Share exercise choices"
        case "jsonl": "Share activity history"
        default: "Share study data"
        }
    }
}

#if DEBUG
// Named destinations open directly; the preview model suppresses background work.
#Preview("Home · Activity") { ContentView(model: WatchPreviewData.model(timer: .saved)) }
#Preview("Home · First launch") { ContentView(model: WatchPreviewData.model(empty: true)) }
#Preview("Choose effort") {
    let model = WatchPreviewData.model()
    return ContentView(model: model, destination: .invitation(model.state.prompts[0].id))
}
#Preview("More") { ContentView(model: WatchPreviewData.model(), destination: .more) }
#Preview("Settings") { ContentView(model: WatchPreviewData.model(), destination: .settings) }
#Preview("Permissions · Granted") { ContentView(model: WatchPreviewData.model(), destination: .permissions) }
#Preview("Permissions · Setup") { ContentView(model: .preview(), destination: .permissions) }
#Preview("Watch activity · Readings") { ContentView(model: WatchPreviewData.model(), destination: .signals) }
#Preview("Watch activity · Empty") { ContentView(model: .preview(), destination: .signals) }
#Preview("Research") { ContentView(model: WatchPreviewData.model(timer: .saved), destination: .log) }
#Preview("Research · Empty") { ContentView(model: .preview(), destination: .log) }
#Preview("Calendars · Granted but empty") {
    NavigationStack { CalendarSelectionView(model: WatchPreviewData.model()) }
}
#Preview("Calendars · Access needed") {
    NavigationStack { CalendarSelectionView(model: .preview()) }
}
#Preview("Available exercises") {
    NavigationStack { ExerciseSelectionView(model: WatchPreviewData.model()) }
}
#Preview("Active hours editor") {
    NavigationStack { AlarmTimeEditor(title: "From", hour: 9, minute: 30, save: { _, _ in }) }
}
#Preview("Timer display guidance") {
    NavigationStack { ScrollView { TimerDisplayGuidance().padding() }.navigationTitle("Timer display") }
}

private struct TimerPreview: View {
    @State private var model: AppModel
    let showingInfo: Bool
    let showingDisplayTip: Bool

    init(_ state: WatchPreviewData.TimerState, showingInfo: Bool = false, showingDisplayTip: Bool = false) {
        _model = State(initialValue: WatchPreviewData.model(timer: state))
        self.showingInfo = showingInfo
        self.showingDisplayTip = showingDisplayTip
    }

    var body: some View {
        NavigationStack {
            ExerciseSessionView(model: model, promptID: model.state.prompts[0].id,
                                showingInfo: showingInfo, showingDisplayTip: showingDisplayTip, onBack: {})
        }
        .defaultAppStorage(UserDefaults(suiteName: "MoveMoment.WatchPreviews")!)
    }
}

#Preview("Timer · Ready") { TimerPreview(.ready) }
#Preview("Timer · Running") { TimerPreview(.running) }
#Preview("Timer · Paused") { TimerPreview(.paused) }
#Preview("Timer · Dimmed") { TimerPreview(.running).environment(\.isLuminanceReduced, true) }
#Preview("Timer · Large text") { TimerPreview(.ready).environment(\.dynamicTypeSize, .xxxLarge) }
#Preview("Completion · Checking") { TimerPreview(.checking) }
#Preview("Completion · Movement detected") { TimerPreview(.detected) }
#Preview("Completion · Little movement") { TimerPreview(.littleMovement) }
#Preview("Completion · Unknown") { TimerPreview(.unknown) }
#Preview("Completion · Saved") { TimerPreview(.saved) }
#Preview("Exercise information") { TimerPreview(.paused, showingInfo: true) }
#Preview("Before you start · Display tip") { TimerPreview(.ready, showingDisplayTip: true) }
#Preview("Timer · No selection") {
    NavigationStack { ExerciseSessionView(model: .preview(), promptID: UUID(), onBack: {}) }
}
#endif
