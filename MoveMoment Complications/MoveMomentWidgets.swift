import SwiftUI
import WidgetKit

struct MovementEntry: TimelineEntry {
    let date: Date
    let snapshot: ComplicationSnapshot
}

struct MovementProvider: TimelineProvider {
    func placeholder(in context: Context) -> MovementEntry {
        preview()
    }

    func getSnapshot(in context: Context, completion: @escaping (MovementEntry) -> Void) {
        let now = Date()
        completion(context.isPreview ? preview() : MovementEntry(date: now, snapshot: ComplicationCache.read(from: ComplicationCache.url) ?? .empty(at: now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MovementEntry>) -> Void) {
        let now = Date()
        let snapshot = ComplicationCache.read(from: ComplicationCache.url) ?? .empty(at: now)
        // Expire invitation text and stale/day-old values even if the app gets no background time.
        let dates = [now] + snapshot.transitionDates(after: now)
        let entries = dates.map { MovementEntry(date: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
        // A WidgetKit reload only updates this display. It does not wake the app's monitoring engine.
    }

    private func preview() -> MovementEntry {
        let now = Date()
        return .init(date: now, snapshot: .init(generatedAt: now, monitoring: true, checkedAt: now,
                                               statusDetail: "Space for a movement break", lowMovementMinutes: 38,
                                               steps: 3250, exerciseMinutes: 18, completedToday: 2,
                                               effortCompletions: ["easy", "easy", "easy", "moderate", "moderate", "challenge"].map {
                                                   .init(date: now, effort: $0)
                                               }))
    }
}

struct MovementComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MovementEntry
    let kind: ComplicationKind

    private var snapshot: ComplicationSnapshot { entry.snapshot }
    private var fresh: Bool { snapshot.isFresh(at: entry.date) }
    private var activityAvailable: Bool { snapshot.hasCurrentActivity(at: entry.date) }
    private var ready: Bool { snapshot.invitationAvailable(at: entry.date) }
    private var count: Int? { snapshot.completions(at: entry.date) }
    private var color: Color {
        switch kind {
        case .moment: ready ? .mint : .cyan
        case .activity: .orange
        case .breaks: .mint
        }
    }
    private var symbol: String {
        switch kind {
        case .moment:
            if !snapshot.dataAvailable { return "figure.walk.circle" }
            if snapshot.activeExerciseTitle != nil { return "figure.flexibility" }
            if !snapshot.monitoring { return "pause.fill" }
            return ready ? "figure.walk" : "sparkles"
        case .activity: return "shoeprints.fill"
        case .breaks: return "checkmark.circle.fill"
        }
    }
    private var value: String {
        switch kind {
        case .moment:
            guard snapshot.monitoring, fresh, let minutes = snapshot.lowMovementMinutes else { return "—" }
            return String(Int(minutes))
        case .activity:
            guard activityAvailable, let steps = snapshot.steps else { return "—" }
            return steps.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        case .breaks: return count.map(String.init) ?? "—"
        }
    }
    private var caption: String {
        switch kind {
        case .moment: ready ? "CHOOSE" : (snapshot.monitoring ? "MIN LOW" : "PAUSED")
        case .activity: "STEPS"
        case .breaks: "BREAKS"
        }
    }

    private var momentLabel: String {
        if !snapshot.dataAvailable { return "SETUP" }
        if snapshot.activeExerciseTitle != nil { return "BREAK" }
        return ready ? "MOVE" : (snapshot.monitoring ? "AUTO" : "OFF")
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryCorner: corner
            case .accessoryInline: inline
            default: rectangular
            }
        }
        .containerBackground(for: .widget) { Color.black }
        .widgetURL(kind.url)
        .privacySensitive()
    }

    @ViewBuilder
    private var circular: some View {
        if kind == .moment, snapshot.monitoring, fresh, !ready, snapshot.activeExerciseTitle == nil, let minutes = snapshot.lowMovementMinutes {
            Gauge(value: min(max(0, minutes), Double(snapshot.inactivityTarget)), in: 0...Double(max(1, snapshot.inactivityTarget))) {
                Image(systemName: "figure.seated.side").widgetAccentable()
            } currentValueLabel: {
                Text(value).font(.system(.title3, design: .rounded).bold())
            }
            .gaugeStyle(.accessoryCircular)
            .tint(color)
            .accessibilityLabel("Last low-movement estimate, \(value) minutes")
        } else {
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: symbol).font(.caption).foregroundStyle(color).widgetAccentable()
                    if kind == .moment {
                        Text(momentLabel)
                            .font(.system(.caption2, design: .rounded).bold()).minimumScaleFactor(0.6)
                    } else {
                        Text(value).font(.system(.title3, design: .rounded).bold()).minimumScaleFactor(0.6)
                    }
                }.padding(4)
            }
            .accessibilityLabel(kind == .moment ? snapshot.title(at: entry.date) : "\(value) \(caption.lowercased()) today")
        }
    }

    private var corner: some View {
        Group {
            if kind == .moment {
                Image(systemName: symbol).font(.system(size: 28, weight: .medium)).widgetAccentable()
            } else {
                Text(value)
                    .font(.system(size: 40, weight: .regular, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .foregroundStyle(kind == .moment ? color : .primary)
        // Keep the larger numeric values aligned with the watch face’s curve.
        .widgetCurvesContent(kind != .moment)
        .widgetLabel {
            switch kind {
            case .moment:
                Text(snapshot.dataAvailable && snapshot.monitoring && fresh && !ready && snapshot.activeExerciseTitle == nil && snapshot.lowMovementMinutes != nil
                     ? "\(value) min low movement" : snapshot.title(at: entry.date))
            case .activity: Text("Steps today").foregroundStyle(Color("AccentColor"))
            case .breaks: Text("Breaks today").foregroundStyle(Color("AccentColor"))
            }
        }
    }

    private var inline: some View {
        Group {
            switch kind {
            case .moment: Label(snapshot.title(at: entry.date), systemImage: symbol)
            case .activity: Label("\(value) steps", systemImage: symbol)
            case .breaks: Label("\(value) breaks today", systemImage: symbol)
            }
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 3) {
            switch kind {
            case .moment:
                Label(snapshot.title(at: entry.date), systemImage: symbol)
                    .font(.headline).foregroundStyle(color).widgetAccentable()
                Text(snapshot.detail(at: entry.date)).font(.caption).lineLimit(2)
                updatedLabel
            case .activity:
                Label("Daily movement", systemImage: symbol).font(.headline).foregroundStyle(color).widgetAccentable()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(value).font(.system(.title2, design: .rounded).bold())
                    Text("steps").font(.caption)
                    Spacer(minLength: 0)
                    Text(activityAvailable ? snapshot.exerciseMinutes.map { "\(Int($0)) min" } ?? "— min" : "— min")
                        .font(.caption.bold())
                }
                updatedLabel
            case .breaks:
                HStack {
                    Label("Movement breaks", systemImage: symbol).font(.headline).foregroundStyle(color).widgetAccentable()
                    Spacer(minLength: 0)
                    Text(value).font(.system(.title2, design: .rounded).bold())
                }
                Text("Reported complete today").font(.caption)
                Text(snapshot.activeExerciseTitle ?? (ready ? "A new break is ready" : "Small breaks add up"))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    @ViewBuilder
    private var updatedLabel: some View {
        if let date = snapshot.checkedAt {
            HStack(spacing: 3) {
                Text(fresh ? "Checked" : "Last check")
                Text(date, style: .time)
            }.font(.caption2).foregroundStyle(.secondary)
        } else {
            Text("Waiting for the first check").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct MomentWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ComplicationKind.moment.rawValue, provider: MovementProvider()) {
            MovementComplicationView(entry: $0, kind: .moment)
        }
        .configurationDisplayName("Moment")
        .description("Monitoring status, your last low-movement estimate, and invitations to move.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

struct ActivityWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ComplicationKind.activity.rawValue, provider: MovementProvider()) {
            MovementComplicationView(entry: $0, kind: .activity)
        }
        .configurationDisplayName("Daily Movement")
        .description("Steps and exercise minutes from the latest automatic check.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

struct BreaksWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ComplicationKind.breaks.rawValue, provider: MovementProvider()) {
            MovementComplicationView(entry: $0, kind: .breaks)
        }
        .configurationDisplayName("Movement Breaks")
        .description("Today's self-reported movement breaks and your current exercise.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryInline, .accessoryRectangular])
    }
}

struct WeeklyEffortView: View {
    @Environment(\.widgetFamily) private var family
    let entry: MovementEntry

    private var counts: [Int] { entry.snapshot.weeklyEffortCounts(at: entry.date) }
    private var total: Int { counts.reduce(0, +) }
    private var markerPosition: Double {
        let counts = counts
        let total = counts.reduce(0, +)
        guard total > 0, let largest = counts.max(), let index = counts.firstIndex(of: largest) else { return 0.5 }
        // Keep the system marker inside the largest slice; ties prefer the first slice.
        let preceding = counts.prefix(index).reduce(0, +)
        return (Double(preceding) + Double(largest) / 2) / Double(total)
    }
    private var gradient: Gradient { effortGradient(counts: counts) }

    private func effortGradient(counts: [Int]) -> Gradient {
        let total = counts.reduce(0, +)
        guard total > 0 else { return Gradient(colors: [.gray.opacity(0.35), .gray.opacity(0.35)]) }
        let colors: [Color] = [.mint, .yellow, .orange]
        var stops: [Gradient.Stop] = []
        var offset = 0.0
        for index in counts.indices where counts[index] > 0 {
            stops.append(.init(color: colors[index], location: offset))
            offset += Double(counts[index]) / Double(total)
            stops.append(.init(color: colors[index], location: min(offset, 1)))
        }
        return Gradient(stops: stops)
    }
    private var summary: String {
        guard total > 0 else { return "No completed movement breaks in the last seven days" }
        let names = ["Low", "Moderate", "High"]
        return "Movement efforts, last seven days. " + counts.indices.map {
            "\(names[$0]) \(Int((Double(counts[$0]) / Double(total) * 100).rounded())) percent"
        }.joined(separator: ", ")
    }

    var body: some View {
        Group {
            if family == .accessoryRectangular { rectangular }
            else { corner }
        }
        .containerBackground(for: .widget) { Color.black }
        .widgetURL(ComplicationKind.breaks.url)
        .privacySensitive()
    }

    private var rectangular: some View {
        let days = entry.snapshot.dailyEffortCounts(at: entry.date)
        let maximum = max(1, days.map { $0.counts.reduce(0, +) }.max() ?? 0)
        return VStack(alignment: .leading, spacing: 3) {
            Label("Weekly effort", systemImage: "figure.walk")
                .font(.headline)
                .foregroundStyle(Color("AccentColor"))
                .widgetAccentable()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            HStack(spacing: 0) {
                ForEach(days) { day in
                    let isToday = Calendar.current.isDate(day.date, inSameDayAs: entry.date)
                    let count = day.counts.reduce(0, +)
                    VStack(spacing: 3) {
                        GeometryReader { geometry in
                            ZStack(alignment: .bottom) {
                                Capsule()
                                    .fill(LinearGradient(colors: [.mint, .yellow, .orange], startPoint: .bottom, endPoint: .top))
                                    .opacity(0.16)
                                if count > 0 {
                                    Capsule()
                                        .fill(LinearGradient(gradient: effortGradient(counts: day.counts), startPoint: .bottom, endPoint: .top))
                                        .frame(height: max(6, geometry.size.height * Double(count) / Double(maximum)))
                                }
                            }
                            .frame(width: 6, height: geometry.size.height)
                            .frame(maxWidth: .infinity)
                        }
                        Text(day.date.formatted(.dateTime.weekday(.narrow)))
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(isToday ? .primary : .secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) {
                        if day.id != days.first?.id {
                            Rectangle().fill(.white.opacity(0.18)).frame(width: 0.5)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(daySummary(day))
                }
            }
        }
    }

    private func daySummary(_ day: ComplicationSnapshot.EffortDay) -> String {
        let date = day.date.formatted(date: .complete, time: .omitted)
        let total = day.counts.reduce(0, +)
        guard total > 0 else { return "\(date). No completed movement breaks" }
        let names = ["Low", "Moderate", "High"]
        return "\(date). \(total) completed breaks. " + day.counts.indices.map {
            "\(names[$0]) \(Int((Double(day.counts[$0]) / Double(total) * 100).rounded())) percent"
        }.joined(separator: ", ")
    }

    private var corner: some View {
        Image(systemName: "figure.walk")
            .font(.system(size: 28, weight: .medium))
            .foregroundStyle(.primary)
            .widgetLabel {
                Gauge(value: markerPosition, in: 0...1) {
                    Text("Weekly effort")
                }
                .gaugeStyle(.accessoryLinear)
                .tint(gradient)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(summary)
    }
}

struct WeeklyEffortWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MoveMoment.WeeklyEffort", provider: MovementProvider()) {
            WeeklyEffortView(entry: $0)
        }
        .configurationDisplayName("Weekly Effort")
        .description("The share of completed breaks at each effort level over the last seven days.")
        .supportedFamilies([.accessoryCorner, .accessoryRectangular])
    }
}

@main
struct MoveMomentWidgetBundle: WidgetBundle {
    var body: some Widget {
        MomentWidget()
        ActivityWidget()
        BreaksWidget()
        WeeklyEffortWidget()
    }
}

private enum ComplicationPreviewData {
    static let date = Date.now
    static let monitoring = MovementEntry(date: date, snapshot: .init(
        generatedAt: date, monitoring: true, checkedAt: date,
        statusDetail: "Space for a movement break", lowMovementMinutes: 18,
        steps: 3250, exerciseMinutes: 18, completedToday: 2
    ))
    static let invitation = MovementEntry(date: date, snapshot: .init(
        generatedAt: date, monitoring: true, checkedAt: date,
        lowMovementMinutes: 38, steps: 3250, exerciseMinutes: 18, completedToday: 2,
        invitationExpiresAt: date.addingTimeInterval(600)
    ))
}

#Preview("Moment · Circular", as: .accessoryCircular) {
    MomentWidget()
} timeline: {
    ComplicationPreviewData.monitoring
    ComplicationPreviewData.invitation
}

#Preview("Moment · Corner", as: .accessoryCorner) {
    MomentWidget()
} timeline: {
    ComplicationPreviewData.monitoring
    ComplicationPreviewData.invitation
}

#Preview("Moment · Inline", as: .accessoryInline) {
    MomentWidget()
} timeline: {
    ComplicationPreviewData.monitoring
    ComplicationPreviewData.invitation
}

#Preview("Moment · Rectangular", as: .accessoryRectangular) {
    MomentWidget()
} timeline: {
    ComplicationPreviewData.monitoring
    ComplicationPreviewData.invitation
}

#Preview("Daily Movement · Circular", as: .accessoryCircular) {
    ActivityWidget()
} timeline: {
    ComplicationPreviewData.monitoring
}

#Preview("Daily Movement · Corner", as: .accessoryCorner) {
    ActivityWidget()
} timeline: {
    ComplicationPreviewData.monitoring
}

#Preview("Daily Movement · Inline", as: .accessoryInline) {
    ActivityWidget()
} timeline: {
    ComplicationPreviewData.monitoring
}

#Preview("Daily Movement · Rectangular", as: .accessoryRectangular) {
    ActivityWidget()
} timeline: {
    ComplicationPreviewData.monitoring
}

#Preview("Movement Breaks · Circular", as: .accessoryCircular) {
    BreaksWidget()
} timeline: {
    ComplicationPreviewData.monitoring
}

#Preview("Movement Breaks · Corner", as: .accessoryCorner) {
    BreaksWidget()
} timeline: {
    ComplicationPreviewData.monitoring
}

#Preview("Movement Breaks · Inline", as: .accessoryInline) {
    BreaksWidget()
} timeline: {
    ComplicationPreviewData.monitoring
}

#Preview("Movement Breaks · Rectangular", as: .accessoryRectangular) {
    BreaksWidget()
} timeline: {
    ComplicationPreviewData.monitoring
}

#Preview("Weekly Effort · Corner", as: .accessoryCorner) {
    WeeklyEffortWidget()
} timeline: {
    MovementEntry(date: ComplicationPreviewData.date, snapshot: .init(
        generatedAt: ComplicationPreviewData.date, monitoring: true,
        effortCompletions: ["easy", "easy", "easy", "moderate", "moderate", "challenge"].map {
            .init(date: ComplicationPreviewData.date, effort: $0)
        }
    ))
    MovementEntry(date: ComplicationPreviewData.date, snapshot: .empty(at: ComplicationPreviewData.date))
}

#Preview("Weekly Effort · Rectangular", as: .accessoryRectangular) {
    WeeklyEffortWidget()
} timeline: {
    MovementEntry(date: ComplicationPreviewData.date, snapshot: .init(
        generatedAt: ComplicationPreviewData.date, monitoring: true,
        effortCompletions: (-6...0).flatMap { offset -> [ComplicationSnapshot.EffortCompletion] in
            let date = Calendar.current.date(byAdding: .day, value: offset, to: ComplicationPreviewData.date)!
            let efforts = offset == -3 ? [] : Array(repeating: "easy", count: -offset + 1)
                + Array(repeating: "moderate", count: 3) + Array(repeating: "challenge", count: offset + 6)
            return efforts.map { .init(date: date, effort: $0) }
        }
    ))
    MovementEntry(date: ComplicationPreviewData.date, snapshot: .empty(at: ComplicationPreviewData.date))
}
