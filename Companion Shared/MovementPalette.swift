import SwiftUI

enum MovementPalette {
    static let low = Color.mint
    static let moderate = Color.yellow
    static let high = Color.orange

    static func effort(_ rawValue: String?) -> Color {
        switch rawValue {
        case "easy": low
        case "moderate": moderate
        case "challenge": high
        default: .gray
        }
    }

    static func completionGradient(_ day: CompanionSnapshot.Day) -> Gradient {
        guard day.completed > 0 else { return Gradient(colors: [.gray]) }
        let counts = [day.low, day.moderate, day.high]
        let colors = [low, moderate, high]
        var stops: [Gradient.Stop] = []
        var offset = 0.0
        for index in counts.indices where counts[index] > 0 {
            stops.append(.init(color: colors[index], location: offset))
            offset += Double(counts[index]) / Double(day.completed)
            stops.append(.init(color: colors[index], location: min(offset, 1)))
        }
        return Gradient(stops: stops)
    }
}
