import SwiftUI

struct PhoneTodayView: View {
    let model: PhoneModel
    let openSettings: () -> Void
    let openPrompt: (UUID) -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ScaledMetric(relativeTo: .largeTitle) private var interventionSize = 96
    @State private var showingSync = false
    @State private var selectedMetric: WeeklyMetric?
    @ScaledMetric(relativeTo: .caption) private var weekColumnWidth = 28
    @State private var scrollOffset: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let spacing: CGFloat = 16

    private var snapshot: CompanionSnapshot? {
        guard let snapshot = model.snapshot, snapshot.dataAvailable else { return nil }
        return snapshot
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            GeometryReader { geometry in
                let contentWidth = min(geometry.size.width, 620) - spacing * 2
                let tileHeight = dynamicTypeSize >= .xLarge ? contentWidth : (contentWidth - spacing) / 2
                let heroHeight = geometry.size.height * 0.5 - spacing
                let fade = max(0, 1 - scrollOffset / max(heroHeight * 0.7, 1))
                ScrollView {
                    VStack(spacing: spacing) {
                        if let snapshot {
                            VStack(spacing: spacing) {
                                hero(snapshot, now: timeline.date)
                                if let prompt = snapshot.prompts.first(where: { $0.outcome == "Scheduled" && $0.expiresAt > timeline.date }) {
                                    invitation(prompt)
                                }
                            }
                            .frame(minHeight: heroHeight)
                            .opacity(fade)
                            .offset(y: reduceMotion ? 0 : scrollOffset * 0.3)
                            .accessibilityHidden(fade == 0)
                            .allowsHitTesting(fade > 0.1)
                            weekCard(snapshot, height: tileHeight)
                            metrics(snapshot, now: timeline.date)
                            syncFooter(snapshot, now: timeline.date)
                        } else {
                            welcome
                        }
                    }
                    .padding(.horizontal, spacing)
                    .padding(.bottom, spacing)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                }
                .scrollEdgeEffectStyle(.soft, for: .top)
                .onScrollGeometryChange(for: CGFloat.self) { scroll in
                    max(0, scroll.contentOffset.y + scroll.contentInsets.top)
                } action: { _, offset in
                    scrollOffset = offset
                }
            }
            .background { watchGlow(at: timeline.date).ignoresSafeArea() }
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
                    }.tint(MovementPalette.low)
                }
            }
            .sheet(item: $selectedMetric) { metric in
                if let snapshot {
                    NavigationStack { DailyDetailView(snapshot: snapshot, metric: metric) }
                        .presentationDetents([.large])
                        .presentationDragIndicator(.hidden)
                        .presentationCornerRadius(32)
                        .preferredColorScheme(.dark)
                        .tint(MovementPalette.low)
                }
            }
            .alert("Sync requested", isPresented: $showingSync) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Open Move Moment on your watch to refresh your day.")
            }
        }
    }

    private func watchGlow(at now: Date) -> some View {
        let day = snapshot?.days.last { Calendar.current.isDate($0.date, inSameDayAs: now) }
        let color = MovementPalette.effort(day?.selections?.dominant)
        return GeometryReader { geometry in
            RadialGradient(
                stops: [
                    .init(color: color.opacity(0.3), location: 0),
                    .init(color: color.opacity(0.1), location: 0.45),
                    .init(color: .clear, location: 1)
                ],
                center: .top,
                startRadius: 0,
                endRadius: geometry.size.width * 1.15
            )
            .background(.black)
        }.accessibilityHidden(true)
    }

    private func hero(_ snapshot: CompanionSnapshot, now: Date) -> some View {
        let today = snapshot.days.last { Calendar.current.isDate($0.date, inSameDayAs: now) }
        return VStack(spacing: 4) {
            Text(now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.subheadline).foregroundStyle(.white.opacity(0.75))
            Text(today.map { $0.completed.formatted() } ?? "—")
                .font(.system(size: interventionSize, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5).lineLimit(1)
                .modifier(PhoneNumericTransition(value: today?.completed))
            Text("breaks completed today")
                .font(.title3).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, spacing)
        .accessibilityElement(children: .combine)
    }

    private func invitation(_ prompt: CompanionSnapshot.Prompt) -> some View {
        Button { openPrompt(prompt.id) } label: {
            Label("Choose a break on your watch", systemImage: "arrow.up.forward")
                .font(.subheadline.weight(.medium))
                .multilineTextAlignment(.center)
                .padding(.vertical, 8)
                .frame(minHeight: 44)
        }.buttonStyle(.plain).foregroundStyle(.mint)
    }

    private func weekCard(_ snapshot: CompanionSnapshot, height: CGFloat) -> some View {
        let maximum = max(snapshot.days.map(\.completed).max() ?? 0, 1)
        return Button { selectedMetric = .breaks } label: {
            card(height: height) {
                VStack(alignment: .leading, spacing: spacing) {
                    HStack {
                        cardTitle("This week", symbol: "calendar")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.6))
                    }
                    if dynamicTypeSize.isAccessibilitySize {
                        ScrollView(.horizontal) {
                            weekBars(snapshot.days, maximum: maximum)
                                .frame(minWidth: weekColumnWidth * 7)
                        }
                    } else {
                        weekBars(snapshot.days, maximum: maximum)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens a chart where you can explore each day")
    }

    private func weekBars(_ days: [CompanionSnapshot.Day], maximum: Int) -> some View {
        HStack(spacing: 8) {
            ForEach(days) { day in
                VStack(spacing: 8) {
                    Text(day.date.formatted(.dateTime.weekday(.narrow)))
                        .font(.caption).foregroundStyle(.white.opacity(0.65))
                    GeometryReader { geometry in
                        ZStack(alignment: .bottom) {
                            Capsule().fill(.white.opacity(0.07))
                            if day.completed > 0 {
                                Capsule()
                                    .fill(LinearGradient(gradient: MovementPalette.completionGradient(day), startPoint: .bottom, endPoint: .top))
                                    .frame(height: max(4, geometry.size.height * Double(day.completed) / Double(maximum)))
                            }
                        }
                        .frame(width: 9, height: geometry.size.height)
                        .frame(maxWidth: .infinity)
                    }
                    Text(day.completed.formatted()).font(.caption.weight(.semibold).monospacedDigit())
                        .modifier(PhoneNumericTransition(value: day.completed))
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(day.date.formatted(.dateTime.weekday(.wide))): \(day.completed) completed breaks, \(day.low) low, \(day.moderate) moderate, \(day.high) high effort")
            }
        }
    }

    private func metrics(_ snapshot: CompanionSnapshot, now: Date) -> some View {
        let checkedToday = snapshot.checkedAt.map { Calendar.current.isDate($0, inSameDayAs: now) } ?? false
        let missed = snapshot.days.last { Calendar.current.isDate($0.date, inSameDayAs: now) }?.missed
        let columns = dynamicTypeSize >= .xLarge ? [GridItem(.flexible(), spacing: spacing)] : [GridItem(.flexible(), spacing: spacing), GridItem(.flexible(), spacing: spacing)]
        return LazyVGrid(columns: columns, spacing: spacing) {
            Button { selectedMetric = .missed } label: {
                metricCard("Missed today", symbol: "clock.badge.xmark", value: missed.map { $0.formatted() } ?? "—", unit: nil,
                           detail: missed == nil ? "Waiting for Watch sync" : "Dismissed or unanswered")
            }
            .buttonStyle(.plain)
            .accessibilityLabel(missed.map { "\($0) missed breaks today" } ?? "Missed breaks unavailable")
            .accessibilityHint("Shows your missed breaks over the week")
            Button { selectedMetric = .steps } label: {
                metricCard("Steps today", symbol: "figure.walk", value: checkedToday ? number(snapshot.steps) : "—", unit: nil,
                           detail: readingFooter(snapshot.checkedAt, now: now))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows your steps over the week")
            Button { selectedMetric = .exercise } label: {
                metricCard("Exercise today", symbol: "timer", value: checkedToday ? number(snapshot.exerciseMinutes) : "—", unit: "min",
                           detail: checkedToday && snapshot.exerciseMinutes != nil ? "Active minutes today" : "Waiting for a reading")
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows your active minutes over the week")
            metricCard("Heart rate", symbol: "heart.fill", value: number(snapshot.heartRate), unit: "bpm",
                       detail: readingFooter(snapshot.heartRateAt, now: now))
        }
    }

    private func metricCard(_ title: String, symbol: String, value: String, unit: String?, detail: String, color: Color = .white.opacity(0.65)) -> some View {
        card(square: true) {
            VStack(alignment: .leading, spacing: 0) {
                cardTitle(title, symbol: symbol, color: color).padding(.bottom, 12)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value).font(.system(.largeTitle, design: .rounded, weight: .medium))
                            .minimumScaleFactor(0.6).lineLimit(1)
                            .modifier(PhoneNumericTransition(value: value))
                        if let unit {
                            Text(unit).font(.subheadline).foregroundStyle(.white.opacity(0.65))
                        }
                    }
                }
                Spacer(minLength: 8)
                Text(detail).font(.caption).foregroundStyle(.white.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.accessibilityElement(children: .combine)
    }

    private func readingFooter(_ date: Date?, now: Date) -> String {
        guard let date else { return "Waiting for a reading" }
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return "Last check at \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "Last check \(date.formatted(.dateTime.day().month(.abbreviated)))\n\(date.formatted(date: .omitted, time: .shortened))"
    }

    private func syncFooter(_ snapshot: CompanionSnapshot, now: Date) -> some View {
        VStack(spacing: 6) {
            Text(snapshot.monitoring ? "Reminders on" : "Reminders paused").font(.caption)
            Text("Watch synced \(snapshot.generatedAt.formatted(date: Calendar.current.isDate(snapshot.generatedAt, inSameDayAs: now) ? .omitted : .abbreviated, time: .shortened))")
                .font(.caption)
            if let checkedAt = snapshot.checkedAt, now.timeIntervalSince(checkedAt) >= 30 * 60 {
                Text("Older activity readings · Open your watch to refresh")
                    .font(.caption).multilineTextAlignment(.center)
            } else if snapshot.checkedAt == nil {
                Text("Waiting for an activity reading").font(.caption)
            }
        }
        .foregroundStyle(.white.opacity(0.65))
        .padding(.top, 6)
    }

    private var welcome: some View {
        VStack(spacing: 28) {
            VStack(spacing: 14) {
                Image(systemName: "applewatch").font(.system(size: 72, weight: .ultraLight)).foregroundStyle(.mint)
                Text("A little movement.\nA brighter day.").font(.largeTitle.weight(.light)).multilineTextAlignment(.center)
            }.padding(.vertical, 38)
            card {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Let’s connect your watch").font(.title3.weight(.semibold))
                    Text("Open Move Moment on your Apple Watch to get started.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                    Button("Connect with my watch", systemImage: "arrow.clockwise") { model.refresh(); showingSync = true }
                        .buttonStyle(.borderedProminent).tint(.mint).foregroundStyle(Color(red: 0.04, green: 0.15, blue: 0.22))
                    Button("Settings", action: openSettings).font(.subheadline).tint(MovementPalette.low)
                }
            }
        }
    }

    private func cardTitle(_ title: String, symbol: String, color: Color = .white.opacity(0.65)) -> some View {
        Label(title.uppercased(), systemImage: symbol)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .accessibilityLabel(title)
    }

    private func card<Content: View>(square: Bool = false, height: CGFloat? = nil, @ViewBuilder content: () -> Content) -> some View {
        Group {
            if square {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay { content().padding(spacing) }
            } else if let height {
                Color.clear.frame(height: height)
                    .overlay { content().padding(spacing) }
            } else {
                content()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(spacing)
            }
        }
        .background(Color(white: reduceTransparency ? 0.09 : 0.055))
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.08), lineWidth: 0.5) }
    }

    private func number(_ value: Double?) -> String { value.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—" }
}

#if DEBUG
#Preview("Today · Connected") {
    NavigationStack { PhoneTodayView(model: .preview(snapshot: PhoneModel.previewSnapshot()), openSettings: {}, openPrompt: { _ in }) }
}

#Preview("Today · Welcome") {
    PhoneContentView(model: .preview())
        .defaultAppStorage(UserDefaults(suiteName: "MoveMoment.PhonePreviews")!)
}

#Preview("Today · Stale readings") {
    NavigationStack { PhoneTodayView(model: .preview(snapshot: PhoneModel.previewSnapshot(stale: true)), openSettings: {}, openPrompt: { _ in }) }
}

#Preview("Today · No interventions yet") {
    NavigationStack { PhoneTodayView(model: .preview(snapshot: PhoneModel.previewSnapshot(emptyDay: true)), openSettings: {}, openPrompt: { _ in }) }
}

#Preview("Today · Moderate effort selected") {
    NavigationStack { PhoneTodayView(model: .preview(snapshot: PhoneModel.previewSnapshot(selectedEffort: "moderate")), openSettings: {}, openPrompt: { _ in }) }
}

#Preview("Today · High effort selected") {
    NavigationStack { PhoneTodayView(model: .preview(snapshot: PhoneModel.previewSnapshot(selectedEffort: "challenge")), openSettings: {}, openPrompt: { _ in }) }
}

#Preview("Today · Narrow layout") {
    NavigationStack { PhoneTodayView(model: .preview(snapshot: PhoneModel.previewSnapshot()), openSettings: {}, openPrompt: { _ in }) }
        .frame(width: 320)
}

#Preview("Today · Missing signals & paused") {
    NavigationStack { PhoneTodayView(model: .preview(snapshot: PhoneModel.previewSnapshot(missingSignals: true)), openSettings: {}, openPrompt: { _ in }) }
}

#Preview("Today · Accessibility text") {
    NavigationStack { PhoneTodayView(model: .preview(snapshot: PhoneModel.previewSnapshot()), openSettings: {}, openPrompt: { _ in }) }
        .environment(\.dynamicTypeSize, .accessibility3)
}

#Preview("Today · Dark mode") {
    NavigationStack { PhoneTodayView(model: .preview(snapshot: PhoneModel.previewSnapshot()), openSettings: {}, openPrompt: { _ in }) }
        .preferredColorScheme(.dark)
}
#endif
