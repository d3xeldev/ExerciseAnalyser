import SwiftUI

private extension Effort {
    var color: Color {
        switch self {
        case .easy: .mint
        case .moderate: .yellow
        case .challenge: .orange
        }
    }
}

private enum WatchDestination: Hashable {
    case preferences, signals, log, more, invitation(UUID), exercise(UUID)
}

struct ContentView: View {
    @State private var model = AppModel.shared
    @State private var path: [WatchDestination] = []

    var body: some View {
        NavigationStack(path: $path) {
            dashboard
                .navigationDestination(for: WatchDestination.self) { destination in
                    switch destination {
                    case .preferences: SettingsView(model: model)
                    case .signals: SignalsView(model: model)
                    case .log: StudyView(model: model)
                    case .more: more
                    case .invitation(let id): invitation(id)
                    case .exercise(let id): ExerciseSessionView(model: model, promptID: id)
                    }
                }
        }
        .onOpenURL { url in
            guard let kind = ComplicationKind.allCases.first(where: { $0.url == url }) else { return }
            model.complicationOpened(kind)
            switch kind {
            case .moment: path = []; openCurrentBreak()
            case .activity: path = [.signals]
            default: path = [.log]
            }
        }
        .onChange(of: model.navigationRequest) { routeRequestedPrompt() }
        .task {
            if model.requestedPromptID != nil { routeRequestedPrompt() }
            else if let prompt = model.activePrompt { path = [.exercise(prompt.id)] }
            while !Task.isCancelled {
                await model.tickExercise()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
        .alert("Move Moment", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK") { model.message = nil }
        } message: { Text(model.message ?? "") }
    }

    private func routeRequestedPrompt() {
        guard let id = model.requestedPromptID,
              let prompt = model.state.prompts.first(where: { $0.id == id }) else { path = []; return }
        if prompt.status == .selected { path = [.exercise(id)] }
        else { path = [.invitation(id)] }
    }

    private func openCurrentBreak() {
        if let prompt = model.activePrompt { path.append(.exercise(prompt.id)) }
        else if let prompt = model.currentPrompt { path.append(.invitation(prompt.id)) }
        else { path.append(.more) }
    }

    private var todayContext: ContextSnapshot? {
        guard let context = model.context, Calendar.current.isDateInToday(context.date) else { return nil }
        return context
    }

    private var dashboard: some View {
        TabView {
            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                statusCard(at: timeline.date)
            }
            metricCard("Steps", value: todayContext?.stepsToday, unit: "steps today", symbol: "shoeprints.fill", color: .blue)
            metricCard("Heart rate", value: model.context?.heartRate?.value, unit: "bpm · latest", symbol: "heart.fill", color: .red,
                       sampledAt: model.context?.heartRate?.date)
        }
        .tabViewStyle(.verticalPage)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Preferences", systemImage: "slider.horizontal.3") { path.append(.preferences) }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("More", systemImage: "ellipsis") { path.append(.more) }
            }
        }
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
            return ("Permissions needed", "Enable \(missingPermissions.joined(separator: ", ")) in Preferences.", "exclamationmark.triangle.fill", .yellow)
        }
        if !model.settings.monitoring {
            return ("Monitoring paused", "Enable monitoring in Preferences.", "pause.circle.fill", .secondary)
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
                    Text(model.checking ? "Reading signals…" : "Connect in Preferences")
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
            Button("Trigger intervention") { model.triggerManualIntervention() }
                .disabled(!model.dataAvailable)
            NavigationLink("Study log", value: WatchDestination.log)
            NavigationLink("Your signals", value: WatchDestination.signals)
        }.navigationTitle("More")
    }

    @ViewBuilder
    private func invitation(_ id: UUID) -> some View {
        if let prompt = model.state.prompts.first(where: { $0.id == id }), prompt.isAvailable(at: Date()) {
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
                Button("Not now") { model.choose(promptID: prompt.id, exerciseID: nil) }.foregroundStyle(.secondary)
            }.navigationTitle("")
        } else {
            ContentUnavailableView("Break unavailable", systemImage: "clock", description: Text("This invitation has ended. A new opportunity will appear on your home screen."))
        }
    }
}

private struct ExerciseSessionView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let model: AppModel
    let promptID: UUID
    @State private var showingInfo = false
    @State private var confirmingEnd = false

    private var prompt: ExercisePrompt? { model.state.prompts.first { $0.id == promptID } }

    var body: some View {
        Group {
            if let prompt, let exercise = prompt.options.first(where: { $0.id == prompt.selectedExerciseID })?.exercise {
                let session = prompt.exerciseSession ?? ExerciseSession()
                if prompt.completedAt != nil || prompt.abandonedAt != nil {
                    ContentUnavailableView("Break saved", systemImage: "checkmark.circle", description: Text("You can find this break in your study log."))
                } else {
                    Group {
                        if session.endedAt != nil { completion(session) }
                        else { timer(exercise: exercise, session: session) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .containerBackground(exercise.effort.color.opacity(0.1).gradient, for: .navigation)
                    .toolbar {
                        ToolbarItemGroup(placement: .bottomBar) {
                            Button(session.endedAt == nil ? "End exercise" : "Didn’t finish", systemImage: "xmark") {
                                confirmingEnd = true
                            }
                            Spacer()
                            if session.endedAt != nil {
                                Button("I did it", systemImage: "checkmark") { model.finish(prompt, completed: true) }
                                    .labelStyle(.iconOnly)
                                    .disabled(session.assessment == nil)
                            } else {
                                Button {
                                    if session.runningSince == nil { model.startExercise(prompt.id) }
                                    else { Task { await model.pauseExercise(prompt.id) } }
                                } label: {
                                    Label(session.runningSince != nil ? "Pause exercise" : (session.startedAt == nil ? "Start exercise" : "Resume exercise"),
                                          systemImage: session.runningSince == nil ? "play.fill" : "pause.fill")
                                }
                                .labelStyle(.iconOnly)
                            }
                            Spacer()
                            Button("Exercise information", systemImage: "info") { showingInfo = true }
                        }
                    }
                    .sheet(isPresented: $showingInfo) {
                        NavigationStack {
                            List {
                                Section(exercise.title) {
                                    Text("\(exercise.minutes) min · \(exercise.effort.title)").foregroundStyle(exercise.effort.color)
                                    Text(exercise.instructions)
                                }
                                Section("Movement check") {
                                    Text(exercise.measurementHint)
                                    Text(session.assessment?.explanation ?? "The movement check is an estimate, not proof that an exercise was done. Missing readings stay unknown.")
                                    Text("This timer doesn’t save a Health workout. Wrist sensing may pause when the app is inactive.").foregroundStyle(.secondary)
                                }
                                Text("Move within your comfort. Stop if you feel pain, dizziness, or unwell.").foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showingInfo = false } } }
                        }
                    }
                    .confirmationDialog("End this break?", isPresented: $confirmingEnd, titleVisibility: .visible) {
                        Button("End break", role: .destructive) { model.finish(prompt, completed: false) }
                        Button("Keep going", role: .cancel) { }
                    }
                }
            } else {
                ContentUnavailableView("No exercise selected", systemImage: "figure.walk")
            }
        }
        .navigationTitle("")
    }

    private func timer(exercise: Exercise, session: ExerciseSession) -> some View {
        VStack(spacing: 4) {
            Text(exercise.title).font(.headline).lineLimit(2).minimumScaleFactor(0.85)
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let remaining = session.remaining(for: exercise, at: timeline.date)
                Text("\(remaining / 60):\(String(format: "%02d", remaining % 60))")
                    .font(.system(size: 58, weight: .medium, design: .rounded))
                    .monospacedDigit().foregroundStyle(exercise.effort.color)
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .contentTransition(.numericText(countsDown: true))
                    .animation(reduceMotion || session.runningSince == nil ? nil : .easeInOut(duration: 0.3), value: remaining)
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
            Section("Background monitoring") {
                eventTime("Last app-refresh wake", kind: "background_refresh_started")
                if let date = model.nextRefreshDate {
                    Text("Requested next: \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption)
                } else { Text("No refresh request pending").font(.caption) }
                let recent = model.state.events.filter { $0.date >= Date().addingTimeInterval(-86400) }
                let checks = recent.filter { $0.kind == "opportunity_evaluated" && $0.attributes["applicationState"] == "background" }.count
                let updates = recent.filter { $0.kind == "health_observer_received" && $0.attributes["applicationState"] == "background" }.count
                Text("24h: \(checks) background checks · \(updates) HealthKit callbacks").font(.caption)
                let expirations = recent.filter { $0.kind == "background_refresh_expired" }.count
                if expirations > 0 { Text("\(expirations) execution windows expired in 24h").font(.caption).foregroundStyle(.yellow) }
                if let failure = model.state.events.last(where: { $0.kind == "background_refresh_failed" }) {
                    Text("Last scheduling error: \(failure.detail ?? "Unknown")").font(.caption).foregroundStyle(.yellow)
                    Text(failure.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2)
                }
                Text("Requested times are not guaranteed. Counts measure actual background execution; older builds did not record these counts.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let context = model.context {
                Section("Latest check") {
                    Text(context.date.formatted(date: .omitted, time: .shortened))
                    ForEach(model.decision?.reasons ?? [], id: \.self) { Text($0).font(.caption) }
                }
                Section("Opportunity") {
                    metric("Low-movement estimate", context.inactivityEstimate, suffix: "min")
                    Text("Calendar: \(context.calendarAvailable ? (context.busy ? "Busy" : "Free") : "Unknown")")
                    metric("Free window", context.freeMinutes, suffix: "min")
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
                Section("Recovery context") {
                    metric("Heart rate", context.heartRate?.value, suffix: "bpm")
                    if let date = context.heartRate?.date { Text("Sample: \(date.formatted(date: .omitted, time: .shortened))").font(.footnote) }
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
                    Section("Unavailable") { ForEach(context.issues, id: \.self) { Text($0).font(.caption) } }
                }
            } else { Text("Signals appear automatically after monitoring starts.") }
            Text("Unknown is not zero. Health read denial and missing samples look the same to apps. Low movement is an estimate, not a measurement of sitting.")
                .font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("Signals")
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

private struct SettingsView: View {
    let model: AppModel

    private func setting<Value>(_ keyPath: WritableKeyPath<Settings, Value>) -> Binding<Value> {
        Binding(get: { model.settings[keyPath: keyPath] }, set: { value in model.updateSettings { $0[keyPath: keyPath] = value } })
    }

    var body: some View {
        Form {
            Section("Monitoring") {
                Toggle("Enabled", isOn: setting(\.monitoring)).disabled(!model.dataAvailable)
                Text("Enabling monitoring will allow your Apple Watch to find the best moments for intervention.").font(.footnote)
            }
            Section("Connect signals") {
                Button(model.healthConfigured ? "Health configured" : "Health access") { Task { await model.requestHealth() } }
                    .disabled(model.healthConfigured)
                Button(model.calendarAccess ? "Calendar enabled" : "Calendar access") { Task { await model.requestCalendar() } }
                    .disabled(model.calendarAccess)
                Button(model.motionAccess ? "Motion enabled" : "Motion access") { Task { await model.requestMotion() } }
                    .disabled(model.motionAccess)
                Button(model.notificationAccess ? "Notifications enabled" : "Allow notifications") { Task { await model.requestNotifications() } }
                    .disabled(model.notificationAccess)
                if model.refreshingAccess { ProgressView("Checking access…") }
            }.disabled(model.requestingAccess || model.refreshingAccess)
            Section("Reminder rhythm") {
                Picker("Inactivity", selection: setting(\.inactivityMinutes)) {
                    ForEach([15, 30, 45, 60, 90], id: \.self) { Text("\($0) min").tag($0) }
                }
                Picker("Cooldown", selection: setting(\.cooldownMinutes)) {
                    ForEach([30, 45, 60, 90, 120, 180], id: \.self) { Text($0 == 0 ? "No cooldown" : "\($0) min").tag($0) }
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
                Text("The first daily reminder gets priority after two active hours, using a 15-minute low-movement threshold. Busy events still block reminders.").font(.footnote)
                Picker("From", selection: setting(\.startHour)) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                Picker("Until", selection: setting(\.endHour)) {
                    ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
                }
                Text("Calendar access is required. Movement reminders wait until busy events finish and there is time for a break.").font(.footnote)
            }
            Section("Explore & learn") {
                Picker("Try new choices", selection: setting(\.explorationRate)) {
                    ForEach([0.0, 0.1, 0.3, 0.5, 1.0], id: \.self) { Text("\(Int($0 * 100))% random").tag($0) }
                }
                Text("Reminder times learn from repeated choices on each weekday, with yesterday’s accepted time as a fallback. After two consecutive misses, cooldown grows by 1.5× for each further miss until midnight.").font(.footnote)
                Text("Other invitations favor exercises you choose. Random invitations ignore preferences and may offer familiar exercises too. Until your first choice, all are random.").font(.footnote)
                NavigationLink("Available exercises") {
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
        }.navigationTitle("Preferences")
            .task { await model.refreshAccessStatus() }
    }
}

private struct StudyView: View {
    let model: AppModel

    var body: some View {
        List {
            Section("On this watch") {
                Text("\(model.state.prompts.count) invitations")
                Text("\(model.state.prompts.filter { $0.selectedExerciseID != nil }.count) choices")
                Text("\(model.state.prompts.filter { $0.completedAt != nil }.count) reported complete")
                Text("\(model.state.events.count) log entries")
                Text("Participant \(model.state.participantID.uuidString.prefix(8))").font(.footnote)
            }
            Section("Export for analysis") {
                Text("Exports include health context, timing, options, selection probabilities, settings, and responses. Share only with your intended researcher.").font(.footnote)
                Button("Prepare research export") { model.prepareExport() }
                ForEach(model.exportURLs, id: \.self) { url in
                    ShareLink(item: url, preview: SharePreview(url.lastPathComponent)) {
                        Label(url.pathExtension.uppercased(), systemImage: "square.and.arrow.up")
                    }
                }
            }
            Section("Recent invitations") {
                ForEach(Array(model.state.prompts.suffix(20).reversed())) { prompt in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(prompt.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                        Text(prompt.method.title).foregroundStyle(.mint)
                        Text(prompt.status.rawValue.capitalized).font(.caption)
                        if let chosen = prompt.options.first(where: { $0.id == prompt.selectedExerciseID }) {
                            Text(chosen.exercise.title).font(.caption)
                        }
                    }
                }
            }
            Text("No response does not mean a reminder was seen. Choosing does not mean an exercise was completed.").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("Study log")
    }
}

#Preview {
    ContentView()
}
