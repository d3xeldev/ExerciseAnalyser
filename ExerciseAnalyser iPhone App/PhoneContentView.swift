import SwiftUI

struct PhoneContentView: View {
    @Bindable var model: PhoneModel
    @State private var tab = 0
    @State private var showingReminder = false

    init(model: PhoneModel, initialTab: Int = 0) {
        self.model = model
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $tab) {
            NavigationStack { today }.tabItem { Label("Today", systemImage: "figure.walk") }.tag(0)
            NavigationStack { research }.tabItem { Label("Research", systemImage: "chart.bar.xaxis") }.tag(1)
            NavigationStack { PhoneSettingsView(model: model) }.tabItem { Label("Settings", systemImage: "slider.horizontal.3") }.tag(2)
        }
        .tint(MovementPalette.low)
        .defaultAppStorage(model.isPreview ? UserDefaults(suiteName: "MoveMoment.PhonePreviews")! : .standard)
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
        PhoneTodayView(model: model, openSettings: { tab = 2 }, openPrompt: { model.openedPromptID = $0 })
    }

    private var research: some View {
        List {
            if let snapshot = model.snapshot, snapshot.dataAvailable {
                Section {
                    LabeledContent("Breaks you completed", value: snapshot.completedBreaks.formatted())
                    LabeledContent("Invitations", value: snapshot.totalPrompts.formatted())
                } header: { Text("Your study so far") } footer: {
                    Text(MovementCopy.completionNote)
                }
                Section("Your recent breaks") {
                    if snapshot.prompts.isEmpty { Text("Your first break will appear here.").foregroundStyle(.secondary) }
                    ForEach(snapshot.prompts) { prompt in
                        NavigationLink { PromptDetailView(prompt: prompt) } label: {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(prompt.selectedTitle ?? "Movement invitation").font(.headline)
                                Text("\(MovementCopy.outcome(prompt.outcome)) · \(prompt.date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }
                    }
                }
                Section("Share with your researcher") {
                    exportActions
                }
                Section("About your data") {
                    NavigationLink {
                        PhoneWatchActivityView(snapshot: snapshot, notificationActivity: model.notificationActivity)
                    } label: {
                        Label("Watch activity", systemImage: "applewatch")
                    }
                    DisclosureGroup("Your study ID") {
                        Text(snapshot.participantID.uuidString).font(.caption.monospaced()).textSelection(.enabled)
                        Text("Use this ID if your researcher asks you to identify your records.").font(.footnote).foregroundStyle(.secondary)
                    }
                    Text(MovementCopy.privacy).font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ContentUnavailableView("Your study starts here", systemImage: "chart.bar.xaxis",
                        description: Text("Open Move Moment on your Watch. Your breaks will appear here after it syncs."))
                }
                Section("Share with your researcher") { exportActions }
            }
        }.navigationTitle("Research")
    }

    private var exportActions: some View {
        Group {
            Button("Prepare my files", systemImage: "square.and.arrow.down") { model.requestExport() }
            Text(model.exportStatus).font(.footnote).foregroundStyle(.secondary)
            if !model.exportURLs.isEmpty {
                ShareLink(items: model.exportURLs) { Label("Share my files", systemImage: "square.and.arrow.up") }
            }
            Text(MovementCopy.shareNote).font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct PhoneWatchActivityView: View {
    let snapshot: CompanionSnapshot
    let notificationActivity: String

    var body: some View {
        List {
            Section("Latest readings") {
                LabeledContent("Watch synced", value: snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Last recorded sleep", value: snapshot.sleepHours.map { $0.formatted(.number.precision(.fractionLength(1))) + " hours" } ?? "Unavailable")
                if snapshot.issues.isEmpty { Text("No reading issues reported.").foregroundStyle(.secondary) }
                ForEach(Array(snapshot.issues.enumerated()), id: \.offset) { _, issue in Text(issue).font(.footnote) }
            }
            Section("Reminder activity") {
                LabeledContent("Watch reminders requested", value: snapshot.requestedNotifications.formatted())
                Text("A requested reminder may not have reached you, for example when notifications are off.").font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup("Latest iPhone activity") { Text(notificationActivity).font(.footnote) }
            }
            Section("Recent updates") {
                ForEach(snapshot.events) { event in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(MovementCopy.eventTitle(event.kind))
                        Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }.navigationTitle("Watch activity").navigationBarTitleDisplayMode(.inline)
    }
}

private struct PromptDetailView: View {
    let prompt: CompanionSnapshot.Prompt

    var body: some View {
        List {
            Section {
                LabeledContent("Status", value: MovementCopy.outcome(prompt.outcome))
                LabeledContent("Invited", value: prompt.date.formatted(date: .abbreviated, time: .shortened))
                LabeledContent("Suggested for you", value: prompt.isManual ? "You asked for a break" : prompt.method)
                if let selected = prompt.selectedTitle { LabeledContent("Your choice", value: selected) }
                Text("Start and finish your break in Move Moment on your Watch.")
                    .font(.footnote).foregroundStyle(.secondary)
                if prompt.expiresAt <= Date() { Text("This invitation has ended. There’ll be another moment to move.").font(.footnote).foregroundStyle(.secondary) }
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

private struct PhoneSettingsView: View {
    let model: PhoneModel
    @AppStorage("phone.reminders") private var reminders = true
    @AppStorage("phone.sound") private var sound = true
    @AppStorage("phone.haptics") private var haptics = true

    var body: some View {
        Form {
            Section {
                Toggle("Movement reminders", isOn: $reminders)
                    .onChange(of: reminders) { _, enabled in if !enabled && !model.isPreview { model.notifications.disableReminders() } }
                Toggle("Reminder sound", isOn: $sound)
                Toggle("Vibrate while app is open", isOn: $haptics)
                Button(model.previewingAlert ? "Playing…" : "Try sound & vibration", systemImage: "speaker.wave.2") { model.previewAlert() }
                    .disabled(model.previewingAlert)
                LabeledContent("Notifications", value: model.notificationStatus)
                Button("Allow notifications", systemImage: "bell.badge") { Task { await model.requestNotifications() } }
                Button("Open iPhone Settings", systemImage: "gear") { model.openSettings() }
            } header: { Text("On your iPhone") } footer: {
                Text("Apple chooses whether reminders appear on your phone or Watch. When this app is closed, your iPhone’s sound and vibration settings apply.")
            }
            Section {
                DisclosureGroup("Reminder settings") {
                    if let snapshot = model.snapshot {
                        LabeledContent("Movement reminders", value: snapshot.monitoring ? "On" : "Paused")
                        ForEach(snapshot.preferences) { detail in LabeledContent(MovementCopy.settingTitle(detail.title), value: detail.value) }
                    } else { Text("Your Watch settings will appear after it syncs.").foregroundStyle(.secondary) }
                }
                DisclosureGroup("Permissions") {
                    if let snapshot = model.snapshot {
                        ForEach(snapshot.permissions) { detail in LabeledContent(detail.title, value: MovementCopy.permissionValue(detail.value)) }
                        Text(MovementCopy.healthNote).font(.footnote).foregroundStyle(.secondary)
                    } else { Text("Open Settings → Permissions on your Watch to get connected.").foregroundStyle(.secondary) }
                }
                NavigationLink {
                    List {
                        Text(MovementCopy.timerIntro)
                        Text(MovementCopy.timerPath)
                        Text(MovementCopy.timerNote).foregroundStyle(.secondary)
                    }.navigationTitle("Timer display").navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Keep your timer on screen", systemImage: "applewatch")
                }
            } header: { Text("On your Watch") } footer: {
                Text("Change your reminder times, permissions, calendars, and exercises in Move Moment → Settings on your Watch.")
            }
            Section("Your devices") {
                Label(model.connectionStatus, systemImage: "applewatch.radiowaves.left.and.right")
                Button("Sync with Watch", systemImage: "arrow.clockwise") { model.refresh() }
                if let snapshot = model.snapshot {
                    Text("Last synced \(snapshot.generatedAt.formatted(date: .abbreviated, time: .shortened))").font(.footnote).foregroundStyle(.secondary)
                }
                Text("Keep your devices nearby with Bluetooth and Background App Refresh on.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Your privacy") {
                Text(MovementCopy.privacy).font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("Settings")
    }
}

#if DEBUG
#Preview("Today · Sample week") {
    PhoneContentView(model: .preview(snapshot: PhoneModel.previewSnapshot()))
}

#Preview("Research · Invitations & events") {
    PhoneContentView(model: .preview(snapshot: PhoneModel.previewSnapshot()), initialTab: 1)
}

#Preview("Research · Before first sync") {
    PhoneContentView(model: .preview(), initialTab: 1)
}

#Preview("Settings · Connected") {
    PhoneContentView(model: .preview(snapshot: PhoneModel.previewSnapshot()), initialTab: 2)
        .defaultAppStorage(UserDefaults(suiteName: "MoveMoment.PhonePreviews")!)
}

#Preview("Settings · Setup") {
    NavigationStack { PhoneSettingsView(model: .preview()) }
        .defaultAppStorage(UserDefaults(suiteName: "MoveMoment.PhonePreviews")!)
}

#Preview("Daily movement · Missing day") {
    NavigationStack { DailyDetailView(snapshot: PhoneModel.previewSnapshot()) }
}

#Preview("Daily movement · No readings") {
    NavigationStack { DailyDetailView(snapshot: PhoneModel.previewSnapshot(missingSignals: true)) }
}

#Preview("Invitation · Active") {
    NavigationStack { PromptDetailView(prompt: PhoneModel.previewSnapshot().prompts[0]) }
}

#Preview("Invitation · Completed & expired") {
    NavigationStack { PromptDetailView(prompt: PhoneModel.previewSnapshot().prompts[1]) }
}

#Preview("Reminder · Not synced") {
    let model = PhoneModel.preview()
    model.openedPromptID = UUID()
    return PhoneContentView(model: model)
}

#Preview("Research · Dark mode") {
    PhoneContentView(model: .preview(snapshot: PhoneModel.previewSnapshot()), initialTab: 1)
        .preferredColorScheme(.dark)
}
#Preview("Settings · Accessibility text") {
    PhoneContentView(model: .preview(snapshot: PhoneModel.previewSnapshot()), initialTab: 2)
        .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Error alert") {
    let model = PhoneModel.preview(snapshot: PhoneModel.previewSnapshot())
    model.error = "Could not save the watch summary. Please try again."
    return PhoneContentView(model: model)
}
#endif
