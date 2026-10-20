import Foundation

/// A point in the day when a preset takes over.
struct ScheduleEntry: Codable, Identifiable, Equatable, Hashable, Sendable {
    enum Trigger: String, Codable, CaseIterable, Sendable {
        case time, sunrise, sunset
    }

    var id = UUID()
    var trigger: Trigger
    /// For `.time`, minutes after midnight. For sunrise and sunset, minutes after (or, when negative, before).
    var minutes: Int
    var presetID: UUID
}

struct Coordinate: Codable, Equatable, Sendable {
    var latitude: Double
    var longitude: Double
}

/// Presets applied through the day, fading from one to the next.
struct BrightnessSchedule: Codable, Equatable, Sendable {
    var isEnabled = false
    var entries: [ScheduleEntry] = []
    var transitionMinutes = 30

    static let transitionChoices = [0, 10, 30, 60]
    static let maximumEntries = 6

    /// Day at sunrise, Evening at sunset, Night at 23:00, using whichever of those presets exist.
    static func suggested(for presets: [Preset]) -> BrightnessSchedule {
        func preset(_ name: String) -> UUID? { presets.first { $0.name == name }?.id }
        var entries: [ScheduleEntry] = []
        if let day = preset("Day") ?? presets.max(by: { $0.level < $1.level })?.id {
            entries.append(ScheduleEntry(trigger: .sunrise, minutes: 0, presetID: day))
        }
        if let evening = preset("Evening") {
            entries.append(ScheduleEntry(trigger: .sunset, minutes: 0, presetID: evening))
        }
        if let night = preset("Night") ?? presets.min(by: { $0.level < $1.level })?.id {
            entries.append(ScheduleEntry(trigger: .time, minutes: 23 * 60, presetID: night))
        }
        return BrightnessSchedule(entries: entries)
    }

    var usesSun: Bool {
        entries.contains { $0.trigger != .time }
    }

    /// Where the schedule stands at `now`. Nil when no entry can be placed, e.g. only
    /// sunrise and sunset entries without a known location.
    func state(at now: Date, location: Coordinate?, calendar: Calendar = .current) -> ScheduleState? {
        var occurrences: [(entry: ScheduleEntry, date: Date)] = []
        for dayOffset in -2...1 {
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) else { continue }
            for entry in entries {
                if let date = Self.date(of: entry, on: day, location: location, calendar: calendar) {
                    occurrences.append((entry, date))
                }
            }
        }
        // Stable for entries at the same moment: the later one in the list wins.
        occurrences = occurrences.enumerated()
            .sorted { ($0.element.date, $0.offset) < ($1.element.date, $1.offset) }
            .map(\.element)

        guard let currentIndex = occurrences.lastIndex(where: { $0.date <= now }),
              currentIndex + 1 < occurrences.count else { return nil }
        let current = occurrences[currentIndex]
        let previous = currentIndex > 0 ? occurrences[currentIndex - 1].entry : nil
        let next = occurrences[currentIndex + 1]

        let elapsed = now.timeIntervalSince(current.date)
        let transition = Double(transitionMinutes * 60)
        let progress = transition > 0 ? min(elapsed / transition, 1) : 1
        return ScheduleState(current: current.entry, startedAt: current.date, previous: previous,
                             progress: progress, next: next.entry, nextAt: next.date)
    }

    static func date(of entry: ScheduleEntry, on day: Date, location: Coordinate?, calendar: Calendar) -> Date? {
        let base: Date?
        switch entry.trigger {
        case .time:
            base = calendar.startOfDay(for: day)
        case .sunrise, .sunset:
            guard let location, let sun = SunTimes(on: day, at: location, calendar: calendar) else { return nil }
            base = entry.trigger == .sunrise ? sun.sunrise : sun.sunset
        }
        return base.map { $0.addingTimeInterval(Double(entry.minutes) * 60) }
    }
}

/// The active entry and how far the fade into it has come.
struct ScheduleState: Equatable, Sendable {
    var current: ScheduleEntry
    var startedAt: Date
    /// The entry before `current`, which the fade starts from.
    var previous: ScheduleEntry?
    /// 0 at `startedAt`, 1 once the transition is over.
    var progress: Double
    var next: ScheduleEntry
    var nextAt: Date

    /// Brightness at this moment, fading linearly from `from` to the current preset's level.
    func level(from start: Double, presets: [Preset]) -> Double? {
        guard let target = presets.first(where: { $0.id == current.presetID })?.level else { return nil }
        return start + (Double(target) - start) * progress
    }
}

/// Sunrise and sunset from NOAA's solar equations, accurate to a minute or two outside the polar regions.
struct SunTimes: Equatable, Sendable {
    let sunrise: Date
    let sunset: Date

    /// Nil during polar day or night, when the sun doesn't rise or set.
    init?(on day: Date, at location: Coordinate, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        guard let midnightUTC = utc.date(from: parts),
              let dayOfYear = utc.ordinality(of: .day, in: .year, for: midnightUTC) else { return nil }

        let gamma = 2 * Double.pi / 365 * (Double(dayOfYear) - 1)
        let equationOfTime = 229.18 * (0.000075 + 0.001868 * cos(gamma) - 0.032077 * sin(gamma)
            - 0.014615 * cos(2 * gamma) - 0.040849 * sin(2 * gamma))
        let declination = 0.006918 - 0.399912 * cos(gamma) + 0.070257 * sin(gamma)
            - 0.006758 * cos(2 * gamma) + 0.000907 * sin(2 * gamma)
            - 0.002697 * cos(3 * gamma) + 0.00148 * sin(3 * gamma)

        let latitude = location.latitude * .pi / 180
        // 90.833°: the sun's centre below the horizon when its upper edge appears, after refraction.
        let cosHourAngle = cos(90.833 * .pi / 180) / (cos(latitude) * cos(declination)) - tan(latitude) * tan(declination)
        guard (-1...1).contains(cosHourAngle) else { return nil }
        let hourAngle = acos(cosHourAngle) * 180 / .pi

        let sunriseMinutes = 720 - 4 * (location.longitude + hourAngle) - equationOfTime
        let sunsetMinutes = 720 - 4 * (location.longitude - hourAngle) - equationOfTime
        sunrise = midnightUTC.addingTimeInterval(sunriseMinutes * 60)
        sunset = midnightUTC.addingTimeInterval(sunsetMinutes * 60)
    }
}
