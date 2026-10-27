import SwiftUI
import Charts

struct PhoneContentView: View {
    @Bindable var model: PhoneModel
    @State private var tab = 0
    @State private var showingReminder = false

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { today }.tabItem { Label("Today", systemImage: "figure.walk") }.tag(0)
            NavigationStack { research }.tabItem { Label("Research", systemImage: "chart.bar.xaxis") }.tag(1)
            NavigationStack { PhonePreferencesView(model: model) }.tabItem { Label("Preferences", systemImage: "slider.horizontal.3") }.tag(2)
        }
        .alert("Move Moment", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .onChange(of: model.openedPromptID) { _, id in
            if id != nil { showingReminder = true }
        }
        .onAppear { showingReminder = model.openedPromptID != nil }
        .sheet(isPresented: $showingReminder, onDismiss: { model.openedPromptID = nil }) {
            NavigationStack {
                if let prompt = model.snapshot?.prompts.first(where: { $0.id == model.openedPromptID }) {
                    PromptDetailView(prompt: prompt)
                        .toolbar { Button("Done") { showingReminder = false } }
                } else {
                    ContentUnavailableView("Your movement break", systemImage: "figure.walk",
                        description: Text("Open Move Moment on your watch to choose an exercise. Its latest invitation has not synced to this phone yet."))
                        .toolbar { Button("Done") { showingReminder = false } }
                }
            }
        }
    }

    private var today: some View {
        PhoneTodayView(model: model, openPreferences: { tab = 2 }, openPrompt: { model.openedPromptID = $0 })
    }

    private var research: some View {
        List {
            if let snapshot = model.snapshot, snapshot.dataAvailable {
                Section("Study overview · all recorded data") {
                    LabeledContent("Invitations", value: String(snapshot.totalPrompts))
                    LabeledContent("Invitations with watch requests", value: String(snapshot.requestedNotifications))
                    LabeledContent("Self-reported completed breaks", value: String(snapshot.completedBreaks))
                    Text("A notification request is not proof of delivery or exposure. Manual invitations and self-reported completion remain distinct in the export.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Recent invitations · latest 30") {
                    if snapshot.prompts.isEmpty { Text("No invitations recorded yet.").foregroundStyle(.secondary) }
                    ForEach(snapshot.prompts) { prompt in
                        NavigationLink { PromptDetailView(prompt: prompt) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(prompt.selectedTitle ?? "Movement invitation").font(.headline); Spacer(); Text(prompt.outcome).font(.caption).foregroundStyle(.secondary) }
                                Text(prompt.date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline).foregroundStyle(.secondary)
                                Text(prompt.isManual ? "Manual intervention" : prompt.method).font(.caption).foregroundStyle(.teal)
                            }.padding(.vertical, 4)
                        }
                    }
                }
                Section("Signal quality") {
                    LabeledContent("Last recorded sleep", value: snapshot.sleepHours.map { String(format: "%.1f hours", $0) } ?? "Unavailable")
                    if snapshot.issues.isEmpty { Text("No signal issues reported in the last summary.").foregroundStyle(.secondary) }
                    ForEach(Array(snapshot.issues.enumerated()), id: \.offset) { _, issue in Text(issue).font(.subheadline) }
                }
                Section("Recent watch events · latest 40") {
                    ForEach(snapshot.events) { event in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(event.kind.replacingOccurrences(of: "_", with: " ").capitalized)
                            Text("\(event.date.formatted(date: .abbreviated, time: .shortened)) · \(event.source)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section("Study identity") {
                    Text(snapshot.participantID.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                    Text("Installation identifier from the watch. No account or server is used.").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section { Text("Research activity appears after the first watch sync.").foregroundStyle(.secondary) }
            }
            Section("Research export") {
                Button("Request complete export", systemImage: "square.and.arrow.down") { model.requestExport() }
                Text(model.exportStatus).font(.footnote).foregroundStyle(.secondary)
                if !model.exportURLs.isEmpty {
                    ShareLink(items: model.exportURLs) { Label("Share last received export", systemImage: "square.and.arrow.up") }
                }
                Text("Includes the study JSON, exercise-choice CSV, event journal, and phone notification activity when available. Files contain sensitive health and study data; choose a trusted destination. Preparing or sharing files does not confirm receipt by a researcher.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle("Research")
    }

}

private struct PromptDetailView: View {
    let prompt: CompanionSnapshot.Prompt

    var body: some View {
        List {
            Section {
                LabeledContent("Outcome", value: prompt.outcome)
                LabeledContent("Created", value: prompt.date.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Selection method", value: prompt.isManual ? "Manual invitation" : prompt.method)
                if let selected = prompt.selectedTitle { LabeledContent("Selected exercise", value: selected) }
                Text("Choose, start, pause, and complete your break on Apple Watch so timing and movement evidence stay together.")
                    .font(.footnote).foregroundStyle(.secondary)
                if prompt.expiresAt <= Date() { Text("This invitation’s response window has ended.").font(.footnote).foregroundStyle(.secondary) }
            }
            ForEach(prompt.options) { option in
                Section("\(option.effort) effort · \(option.minutes) min") {
                    Label(option.title, systemImage: option.symbol).font(.headline)
                    Text(option.instructions)
                }
            }
        }.navigationTitle("Movement break").navigationBarTitleDisplayMode(.inline)
    }
}

struct DailyDetailView: View {
    let snapshot: CompanionSnapshot
    var body: some View {
        List {
            Section("Recorded daily steps") {
                if snapshot.days.contains(where: { $0.steps != nil }) {
                    Chart(snapshot.days.filter { $0.steps != nil }) { day in
                        BarMark(x: .value("Day", day.date, unit: .day), y: .value("Steps", day.steps ?? 0)).foregroundStyle(.teal)
                    }.frame(height: 200)
                }
                Text("Missing days are not plotted as zero. Dates reflect the watch’s last summary.").font(.caption).foregroundStyle(.secondary)
            }
            ForEach(snapshot.days.reversed()) { day in
                Section(day.date.formatted(date: .complete, time: .omitted)) {
                    LabeledContent("Steps", value: day.steps.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "Unavailable")
                    LabeledContent("Completed breaks", value: String(day.completed))
                    Text("Low \(day.low) · Moderate \(day.moderate) · High \(day.high)").font(.caption).foregroundStyle(.secondary)
                }
            }
        }.navigationTitle("Daily movement").navigationBarTitleDisplayMode(.inline)
    }
}

private struct PhonePreferencesView: View {
    let model: PhoneModel
    @AppStorage("phone.reminders") private var reminders = true
    @AppStorage("phone.sound") private var sound = true
    @AppStorage("phone.haptics") private var haptics = true

    var body: some View {
        Form {
            Section {
                Toggle("Movement reminders on iPhone", isOn: $reminders)
                    .onChange(of: reminders) { _, enabled in if !enabled { model.notifications.disableReminders() } }
                Toggle("Custom movement chime", isOn: $sound)
                Toggle("Haptics while app is open", isOn: $haptics)
                Button(model.previewingAlert ? "Playing preview…" : "Preview chime & haptics", systemImage: "speaker.wave.2") { model.previewAlert() }
                    .disabled(model.previewingAlert)
                LabeledContent("Notifications", value: model.notificationStatus)
                LabeledContent("Notification sound", value: model.soundStatus)
                Button("Allow notifications", systemImage: "bell.badge") { Task { await model.requestNotifications() } }
                Button("Open iPhone Settings", systemImage: "gear") { model.openSettings() }
            } header: { Text("iPhone reminders") } footer: {
                Text("Your watch and phone coordinate the same reminder, with exercise and delay actions on either alert. Apple chooses where it appears; late phone copies are skipped to avoid a second alert. Custom haptics work while this app is open. iOS controls background vibration and sound. Sound changes apply to future reminders.")
            }
            Section("Last phone notification activity") {
                Text(model.notificationActivity).font(.footnote)
            }
            Section("Keep the watch timer visible") {
                Label("Set Return to Clock to 1 hour", systemImage: "applewatch")
                Text("On your Apple Watch: Settings → General → Return to Clock → ExerciseAnalyser → Custom → After 1 hour.")
                    .font(.footnote)
                Text("This avoids the usual automatic return to the watch face during a movement break. The display can still dim, and you can leave the app at any time.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Watch permissions") {
                if let snapshot = model.snapshot {
                    ForEach(snapshot.permissions) { detail in LabeledContent(detail.title, value: detail.value) }
                    Text("Reported \(snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                }
                Text("Open Move Moment → Preferences on Apple Watch to request Health, Calendar, Motion, and watch notification access. Phone permissions do not grant watch access. HealthKit does not reveal individual read grants.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Research preferences on watch") {
                if let snapshot = model.snapshot {
                    LabeledContent("Monitoring", value: snapshot.monitoring ? "Enabled" : "Paused")
                    ForEach(snapshot.preferences) { detail in LabeledContent(detail.title, value: detail.value) }
                }
                Text("Change active hours, reminder frequency, calendars, and enabled exercises in the watch’s Preferences. This phone displays the saved configuration from the last sync.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Connection & privacy") {
                Label(model.connectionStatus, systemImage: "applewatch.radiowaves.left.and.right")
                Button("Request watch summary", systemImage: "arrow.clockwise") { model.refresh() }
                Text("Keep Bluetooth and Background App Refresh enabled for both apps. The watch collects the research signals; the phone does not request duplicate Health, Motion, or Calendar access. Summaries and requested exports stay on your paired devices until you share them. No account, analytics SDK, or server is used.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Preferences")
    }
}
