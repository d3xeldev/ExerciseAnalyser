import SwiftUI

enum WeeklyMetric: String, Identifiable {
    case breaks, steps, exercise, missed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .breaks: "This week"
        case .steps: "Steps"
        case .exercise: "Exercise"
        case .missed: "Missed"
        }
    }

    func value(for day: CompanionSnapshot.Day) -> Double? {
        switch self {
        case .breaks: Double(day.completed)
        case .steps: day.steps
        case .exercise: day.exerciseMinutes
        case .missed: day.missed.map(Double.init)
        }
    }

    func caption(for day: CompanionSnapshot.Day) -> String {
        switch self {
        case .breaks: day.completed == 1 ? "break completed" : "breaks completed"
        case .steps: "steps"
        case .exercise: "active minutes"
        case .missed: day.missed == 1 ? "missed break" : "missed breaks"
        }
    }

    func gradient(for day: CompanionSnapshot.Day) -> Gradient {
        switch self {
        case .breaks: MovementPalette.completionGradient(day)
        case .steps: Gradient(colors: [MovementPalette.steps])
        case .exercise: Gradient(colors: [MovementPalette.exercise])
        case .missed: Gradient(colors: [MovementPalette.missed])
        }
    }

    func formattedValue(for day: CompanionSnapshot.Day) -> String {
        value(for: day).map { $0.formatted(.number.precision(.fractionLength(0))) } ?? "—"
    }

    func accessibilityValue(for day: CompanionSnapshot.Day) -> String {
        guard value(for: day) != nil else { return "No reading" }
        if self == .breaks {
            return "\(day.completed) completed breaks: \(day.low) low, \(day.moderate) moderate, \(day.high) high effort"
        }
        return "\(formattedValue(for: day)) \(caption(for: day))"
    }
}

struct DailyDetailView: View {
    let snapshot: CompanionSnapshot
    let metric: WeeklyMetric
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedIndex: Int
    @ScaledMetric(relativeTo: .caption) private var chartLabelHeight = 20
    @ScaledMetric(relativeTo: .caption2) private var chartAxisWidth = 32

    init(snapshot: CompanionSnapshot, metric: WeeklyMetric = .breaks) {
        self.snapshot = snapshot
        self.metric = metric
        _selectedIndex = State(initialValue: max(0, snapshot.days.count - 1))
    }

    private var selectedDay: CompanionSnapshot.Day? {
        snapshot.days.indices.contains(selectedIndex) ? snapshot.days[selectedIndex] : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let day = selectedDay {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(metric.formattedValue(for: day))
                            .font(.system(.largeTitle, design: .rounded, weight: .bold))
                            .modifier(PhoneNumericTransition(value: metric.formattedValue(for: day)))
                        Text(metric.value(for: day) == nil ? "No reading" : metric.caption(for: day))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.accessibilityElement(children: .combine)
                    weekChart
                    Text(day.date.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    if metric == .breaks {
                        Divider()
                        if dynamicTypeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 16) { effortDetails(day) }
                        } else {
                            HStack(spacing: 16) { effortDetails(day) }
                        }
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
        .navigationTitle(metric.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .tint(.white)
            }
        }
    }

    private var weekChart: some View {
        let step = max(1, Int(ceil((snapshot.days.compactMap { metric.value(for: $0) }.max() ?? 0) / 4)))
        let maximum = step * 4
        let plotHeight: CGFloat = 200
        let barWidth: CGFloat = 14
        let selectionPadding: CGFloat = 8
        let labelSpacing = selectionPadding + 10
        return GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                chartGrid(width: width, height: plotHeight, maximum: maximum)
                HStack(alignment: .top, spacing: 0) {
                    ForEach(Array(snapshot.days.enumerated()), id: \.element.id) { index, day in
                        let value = metric.value(for: day)
                        let barHeight = max(3, plotHeight * CGFloat(value ?? 0) / CGFloat(maximum))
                        Button { selectedIndex = index } label: {
                            VStack(spacing: labelSpacing) {
                                Capsule()
                                    .fill(LinearGradient(gradient: (value ?? 0) > 0 ? metric.gradient(for: day) : Gradient(colors: [.white.opacity(value == nil ? 0.15 : 0.5)]), startPoint: .bottom, endPoint: .top))
                                    .frame(width: barWidth, height: barHeight)
                                    .opacity(index == selectedIndex ? 1 : 0.75)
                                    .background {
                                        Capsule()
                                            .fill(index == selectedIndex ? .white.opacity(0.12) : .clear)
                                            .padding(-selectionPadding)
                                    }
                                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                                    .frame(height: plotHeight)
                                Text(day.date.formatted(.dateTime.weekday(.narrow)))
                                    .font(.caption.weight(index == selectedIndex ? .bold : .regular))
                                    .foregroundStyle(index == selectedIndex ? .white : .white.opacity(0.6))
                                    .frame(height: chartLabelHeight)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
                        .accessibilityValue(metric.accessibilityValue(for: day))
                        .accessibilityAddTraits(index == selectedIndex ? .isSelected : [])
                        .accessibilityHint("Shows this day’s details")
                    }
                }
                .padding(.trailing, chartAxisWidth)
            }
            .frame(width: width, height: plotHeight + labelSpacing + chartLabelHeight)
            .padding(.top, max(selectionPadding, chartLabelHeight / 2))
        }
        .frame(height: plotHeight + labelSpacing + chartLabelHeight + max(selectionPadding, chartLabelHeight / 2))
    }

    private func chartGrid(width: CGFloat, height: CGFloat, maximum: Int) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(0...4, id: \.self) { tick in
                let y = height * CGFloat(tick) / 4
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width - chartAxisWidth, y: y))
                }.stroke(.white.opacity(0.08), lineWidth: 0.5)
                Text((maximum - tick * maximum / 4).formatted())
                    .font(.caption2).foregroundStyle(.white.opacity(0.55))
                    .frame(width: chartAxisWidth)
                    .position(x: width - chartAxisWidth / 2, y: y)
            }
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
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
                .modifier(PhoneNumericTransition(value: count))
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

#Preview("Weekly steps") {
    NavigationStack { DailyDetailView(snapshot: PhoneModel.previewSnapshot(), metric: .steps) }
        .preferredColorScheme(.dark).tint(MovementPalette.low)
}

#Preview("Weekly exercise") {
    NavigationStack { DailyDetailView(snapshot: PhoneModel.previewSnapshot(), metric: .exercise) }
        .preferredColorScheme(.dark).tint(MovementPalette.low)
}

#Preview("Weekly missed breaks") {
    NavigationStack { DailyDetailView(snapshot: PhoneModel.previewSnapshot(), metric: .missed) }
        .preferredColorScheme(.dark).tint(MovementPalette.low)
}

#Preview("Weekly sheet · No completed breaks") {
    NavigationStack { DailyDetailView(snapshot: PhoneModel.previewSnapshot(emptyDay: true)) }
        .preferredColorScheme(.dark).tint(MovementPalette.low)
}
#endif
