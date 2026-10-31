import SwiftUI
import Charts

struct DailyDetailView: View {
    let snapshot: CompanionSnapshot
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedIndex: Int
    @State private var chartSelection: Int?

    init(snapshot: CompanionSnapshot) {
        self.snapshot = snapshot
        _selectedIndex = State(initialValue: max(0, snapshot.days.count - 1))
    }

    private var selectedDay: CompanionSnapshot.Day? {
        snapshot.days.indices.contains(selectedIndex) ? snapshot.days[selectedIndex] : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let day = selectedDay {
                    daySelector(day)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(day.completed.formatted())
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .contentTransition(.numericText())
                        Text(day.completed == 1 ? "break completed" : "breaks completed")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                    weekChart
                    Text("Tap a day to explore").font(.caption).foregroundStyle(.secondary)
                    Divider()
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 16) { effortDetails(day) }
                    } else {
                        HStack(spacing: 16) { effortDetails(day) }
                    }
                    Divider()
                    LabeledContent("Missed", value: day.missed.map { $0.formatted() } ?? "Unavailable")
                    LabeledContent("Steps", value: day.steps.map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "Unavailable")
                    DisclosureGroup("What counts as missed?") {
                        Text("Dismissed, expired, or unanswered invitations. Active breaks and breaks you ended yourself aren’t included.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView("Your week is on its way", systemImage: "calendar",
                        description: Text("Your daily activity will appear after your Watch syncs."))
                }
            }
            .padding(24)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Color(.systemBackground))
        .navigationTitle("Movement breaks")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly)
            }
        }
        .onChange(of: chartSelection) { _, index in
            if let index, snapshot.days.indices.contains(index) { selectedIndex = index }
        }
    }

    private func daySelector(_ day: CompanionSnapshot.Day) -> some View {
        HStack {
            Button("Previous day", systemImage: "chevron.left") { selectedIndex -= 1 }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                .disabled(selectedIndex == 0)
            Spacer(minLength: 0)
            Text(day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.headline).multilineTextAlignment(.center)
            Spacer(minLength: 0)
            Button("Next day", systemImage: "chevron.right") { selectedIndex += 1 }
                .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                .disabled(selectedIndex >= snapshot.days.count - 1)
        }
    }

    private var weekChart: some View {
        Chart {
            ForEach(Array(snapshot.days.enumerated()), id: \.element.id) { index, day in
                BarMark(x: .value("Day", index), y: .value("Breaks", day.low), width: .ratio(0.55))
                    .foregroundStyle(by: .value("Effort", "Low"))
                    .opacity(index == selectedIndex ? 1 : 0.4)
                BarMark(x: .value("Day", index), y: .value("Breaks", day.moderate), width: .ratio(0.55))
                    .foregroundStyle(by: .value("Effort", "Moderate"))
                    .opacity(index == selectedIndex ? 1 : 0.4)
                BarMark(x: .value("Day", index), y: .value("Breaks", day.high), width: .ratio(0.55))
                    .foregroundStyle(by: .value("Effort", "High"))
                    .opacity(index == selectedIndex ? 1 : 0.4)
            }
            RuleMark(x: .value("Selected day", selectedIndex))
                .foregroundStyle(.secondary.opacity(0.5))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .accessibilityHidden(true)
        }
        .chartForegroundStyleScale(domain: ["Low", "Moderate", "High"], range: [MovementPalette.low, MovementPalette.moderate, MovementPalette.high])
        .chartLegend(.hidden)
        .chartXScale(domain: -0.5...Double(max(0, snapshot.days.count - 1)) + 0.5)
        .chartYScale(domain: 0...max(4, snapshot.days.map(\.completed).max() ?? 0))
        .chartXAxis {
            AxisMarks(values: Array(snapshot.days.indices)) { value in
                if let index = value.as(Int.self), snapshot.days.indices.contains(index) {
                    AxisValueLabel {
                        Text(snapshot.days[index].date.formatted(.dateTime.weekday(.narrow)))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                if let count = value.as(Int.self) {
                    AxisGridLine().foregroundStyle(.secondary.opacity(0.2))
                    AxisValueLabel { Text(count.formatted()) }
                }
            }
        }
        .chartXSelection(value: $chartSelection)
        .chartGesture { proxy in
            SpatialTapGesture().onEnded { tap in proxy.selectXValue(at: tap.location.x) }
        }
        .frame(height: 220)
        .accessibilityLabel("Completed movement breaks by day and effort")
    }

    @ViewBuilder
    private func effortDetails(_ day: CompanionSnapshot.Day) -> some View {
        effortValue("Low", count: day.low, color: MovementPalette.low)
        effortValue("Moderate", count: day.moderate, color: MovementPalette.moderate)
        effortValue("High", count: day.high, color: MovementPalette.high)
    }

    private func effortValue(_ title: String, count: Int, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(title).foregroundStyle(.secondary)
            } icon: {
                Circle().fill(color).frame(width: 8, height: 8)
            }.font(.caption)
            Text(count.formatted()).font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
#Preview("Weekly sheet") {
    NavigationStack { DailyDetailView(snapshot: PhoneModel.previewSnapshot()) }
        .preferredColorScheme(.dark).tint(MovementPalette.low)
}

#Preview("Weekly sheet · No completed breaks") {
    NavigationStack { DailyDetailView(snapshot: PhoneModel.previewSnapshot(emptyDay: true)) }
        .preferredColorScheme(.dark).tint(MovementPalette.low)
}
#endif
