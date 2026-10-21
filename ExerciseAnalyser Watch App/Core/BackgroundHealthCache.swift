import Foundation

struct CachedHealthValue<Value: Codable>: Codable {
    let value: Value
    let collectedAt: Date
    let timeZoneIdentifier: String
    let provenance: SignalProvenance

    func usable(at now: Date, calendar: Calendar = .current) -> Bool {
        let age = now.timeIntervalSince(collectedAt)
        return age >= 0 && age < 3600 && timeZoneIdentifier == calendar.timeZone.identifier
            && calendar.isDate(collectedAt, inSameDayAs: now)
    }

    var cachedProvenance: SignalProvenance {
        .init(source: "HealthKit_cache", unit: provenance.unit, windowStart: provenance.windowStart,
              windowEnd: provenance.windowEnd, sampleDate: provenance.sampleDate, availability: provenance.availability)
    }
}

// Only slow-changing aggregates belong here. Wear, movement, workouts and calendar are read every time.
struct BackgroundHealthCache: Codable {
    var stepHistory: CachedHealthValue<[ComplicationSnapshot.DailyTotal]>?
    var restingHeartRate: CachedHealthValue<Measurement>?
    var sleepHours: CachedHealthValue<Double>?

    func available(at now: Date, calendar: Calendar = .current) -> Self {
        var result = self
        if stepHistory?.usable(at: now, calendar: calendar) != true { result.stepHistory = nil }
        if restingHeartRate?.usable(at: now, calendar: calendar) != true { result.restingHeartRate = nil }
        if sleepHours?.usable(at: now, calendar: calendar) != true { result.sleepHours = nil }
        return result
    }
}
