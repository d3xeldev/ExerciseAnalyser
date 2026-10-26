import SwiftUI

struct PhoneTodayView: View {
    let model: PhoneModel
    let openPreferences: () -> Void
    let openPrompt: (UUID) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .largeTitle) private var stepSize = 88
    @State private var showingSync = false

    private var snapshot: CompanionSnapshot? {
        guard let snapshot = model.snapshot, snapshot.dataAvailable else { return nil }
        return snapshot
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            ScrollView {
                VStack(spacing: 18) {
                    if let snapshot {
                        hero(snapshot, now: timeline.date)
                        if let prompt = snapshot.prompts.first(where: { $0.outcome == "Scheduled" && $0.expiresAt > timeline.date }) {
                            invitation(prompt)
                        }
                        weekCard(snapshot)
                        metrics(snapshot, now: timeline.date)
                        syncFooter(snapshot, now: timeline.date)
                    } else {
                        welcome
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 28)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background { sky.ignoresSafeArea() }
            .foregroundStyle(.white)
            .navigationTitle("Move Moment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sync with watch", systemImage: "arrow.clockwise") {
                        model.refresh()
                        showingSync = true
                    }.tint(.white)
                }
            }
            .alert("Sync requested", isPresented: $showingSync) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Your watch will send its latest summary when connected. Open Move Moment on your watch for a fresh activity check.")
            }
        }
    }

    private var sky: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(red: 0.08, green: 0.29, blue: 0.40), Color(red: 0.06, green: 0.17, blue: 0.29), Color(red: 0.04, green: 0.10, blue: 0.20)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle()
                    .fill(RadialGradient(colors: [Color.cyan.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: geometry.size.width * 0.65))
                    .frame(width: geometry.size.width * 1.3, height: geometry.size.width * 1.3)
                    .offset(x: -geometry.size.width * 0.35, y: -80)
            }
        }.accessibilityHidden(true)
    }

    private func hero(_ snapshot: CompanionSnapshot, now: Date) -> some View {
        let steps = snapshot.checkedAt.map { Calendar.current.isDate($0, inSameDayAs: now) } == true ? snapshot.steps : nil
        return VStack(spacing: 8) {
            Text(now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.subheadline).foregroundStyle(.white.opacity(0.75))
            Image(systemName: "figure.walk")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color(red: 0.60, green: 0.95, blue: 0.86))
                .padding(.top, 16)
            Text(steps.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—")
                .font(.system(size: stepSize, weight: .thin, design: .rounded))
                .minimumScaleFactor(0.5).lineLimit(1)
                .contentTransition(.numericText())
            Text("steps today").font(.title3)
            Text(steps == nil ? "Your next watch update will fill this in." : "A little movement adds up.")
                .font(.subheadline).foregroundStyle(.white.opacity(0.75))
            HStack(spacing: 6) {
                Image(systemName: snapshot.monitoring ? "waveform.path" : "pause.fill")
                Text(snapshot.monitoring ? "Watching for a good moment" : "Monitoring paused")
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(.white.opacity(0.10), in: Capsule())
            .padding(.top, 10)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12).padding(.bottom, 14)
        .accessibilityElement(children: .combine)
    }

    private func invitation(_ prompt: CompanionSnapshot.Prompt) -> some View {
        Button { openPrompt(prompt.id) } label: {
            card {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: "figure.flexibility")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Color(red: 0.63, green: 0.96, blue: 0.85))
                    VStack(alignment: .leading, spacing: 5) {
                        Text("A moment for you").font(.headline)
                        Text("Three little ways to move. Choose on your watch.")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.65))
                }
            }
        }.buttonStyle(.plain)
    }

    private func weekCard(_ snapshot: CompanionSnapshot) -> some View {
        let total = snapshot.days.reduce(0) { $0 + $1.completed }
        let maximum = max(snapshot.days.map(\.completed).max() ?? 0, 1)
        return NavigationLink {
            DailyDetailView(snapshot: snapshot)
        } label: {
            card {
                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        cardTitle("YOUR WEEK", symbol: "calendar")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                    }
                    Text(total == 1 ? "1 movement break" : "\(total) movement breaks")
                        .font(.title3.weight(.medium))
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach(snapshot.days) { day in
                            VStack(spacing: 10) {
                                Text(day.completed.formatted()).font(.subheadline.weight(.medium).monospacedDigit())
                                ZStack(alignment: .bottom) {
                                    Capsule().fill(.white.opacity(0.07))
                                    if day.completed > 0 {
                                        Capsule().fill(LinearGradient(colors: [.mint, .cyan.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                                            .frame(height: max(8, 46 * Double(day.completed) / Double(maximum)))
                                    }
                                }.frame(width: 7, height: 46)
                                Text(day.date.formatted(.dateTime.weekday(.narrow)))
                                    .font(.caption).foregroundStyle(.white.opacity(0.75))
                            }
                            .frame(maxWidth: .infinity)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("\(day.date.formatted(.dateTime.weekday(.wide))): \(day.completed) completed breaks")
                        }
                    }
                    if total == 0 {
                        Text("Your first completed break starts the story.").font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                }
            }
        }.buttonStyle(.plain)
    }

    private func metrics(_ snapshot: CompanionSnapshot, now: Date) -> some View {
        let today = snapshot.days.last { Calendar.current.isDate($0.date, inSameDayAs: now) }
        let checkedToday = snapshot.checkedAt.map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false
        let columns = dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: columns, spacing: 14) {
            metricCard("BREAKS", symbol: "figure.cooldown", value: today.map { String($0.completed) } ?? "—", unit: "today",
                       detail: today.map { "\($0.low) low · \($0.moderate) moderate · \($0.high) high" } ?? "Waiting for today’s update", accent: .mint)
            metricCard("EXERCISE", symbol: "timer", value: checkedToday ? number(snapshot.exerciseMinutes) : "—", unit: "minutes",
                       detail: "Activity recorded today", accent: .cyan)
            metricCard("HEART RATE", symbol: "heart.fill", value: number(snapshot.heartRate), unit: "bpm",
                       detail: snapshot.heartRateAt.map { "Last reading \($0.formatted(date: Calendar.current.isDate($0, inSameDayAs: now) ? .omitted : .abbreviated, time: .shortened))" } ?? "No recent reading", accent: .pink)
            metricCard("SLEEP", symbol: "moon.stars.fill", value: snapshot.sleepHours.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "—", unit: "hours",
                       detail: "Last recorded 24-hour window", accent: Color(red: 0.76, green: 0.73, blue: 1))
        }
    }

    private func metricCard(_ title: String, symbol: String, value: String, unit: String, detail: String, accent: Color) -> some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                cardTitle(title, symbol: symbol)
                Image(systemName: symbol).font(.system(size: 25, weight: .light)).foregroundStyle(accent).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(value).font(.system(.largeTitle, design: .rounded, weight: .regular)).contentTransition(.numericText())
                    Text(unit).font(.subheadline).foregroundStyle(.white.opacity(0.8))
                }
                Text(detail).font(.caption).foregroundStyle(.white.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }.frame(maxWidth: .infinity, minHeight: 175, alignment: .topLeading)
        }.accessibilityElement(children: .combine)
    }

    private func syncFooter(_ snapshot: CompanionSnapshot, now: Date) -> some View {
        VStack(spacing: 6) {
            Label("From your Apple Watch", systemImage: "applewatch").font(.caption.weight(.medium))
            if let checkedAt = snapshot.checkedAt {
                Text("Updated \(checkedAt.formatted(date: Calendar.current.isDate(checkedAt, inSameDayAs: now) ? .omitted : .abbreviated, time: .shortened))")
                    .font(.caption)
                if now.timeIntervalSince(checkedAt) >= 30 * 60 {
                    Text("These readings are a little older. Open the watch app to refresh.")
                        .font(.caption).multilineTextAlignment(.center)
                }
            } else { Text("Waiting for the first activity check").font(.caption) }
        }
        .foregroundStyle(.white.opacity(0.65))
        .padding(.top, 6)
    }

    private var welcome: some View {
        VStack(spacing: 28) {
            VStack(spacing: 14) {
                Image(systemName: "applewatch").font(.system(size: 72, weight: .ultraLight)).foregroundStyle(.mint)
                Text("A little movement.\nA brighter day.").font(.largeTitle.weight(.light)).multilineTextAlignment(.center)
                Text("Your day, at a glance — right here.").font(.subheadline).foregroundStyle(.white.opacity(0.75))
            }.padding(.vertical, 38)
            card {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Let’s connect your watch").font(.title3.weight(.semibold))
                    Text("Open Move Moment on your Apple Watch and finish setup. Your activity will appear here after the first sync.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    Button("Connect with my watch", systemImage: "arrow.clockwise") { model.refresh(); showingSync = true }
                        .buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(Color(red: 0.04, green: 0.15, blue: 0.22))
                    Button("Permissions & preferences", action: openPreferences).font(.subheadline).tint(.white)
                }
            }
        }
    }

    private func cardTitle(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(reduceTransparency ? Color(red: 0.10, green: 0.23, blue: 0.33) : .white.opacity(0.075), in: RoundedRectangle(cornerRadius: 24))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.10), lineWidth: 0.5) }
    }

    private func number(_ value: Double?) -> String { value.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—" }
}
