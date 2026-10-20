import Foundation
import Testing

@Suite struct ScheduleTests {
    static let amsterdam = Coordinate(latitude: 52.37, longitude: 4.90)

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Amsterdam")!
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    static func minutesAfterMidnight(_ date: Date) -> Int {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return parts.hour! * 60 + parts.minute!
    }

    @Test func sunTimesMatchPublishedTables() throws {
        // timeanddate.com, Amsterdam: 21 June sunrise 05:18 / sunset 22:06 CEST; 21 December 08:48 / 16:29 CET.
        let summer = try #require(SunTimes(on: Self.date(2026, 6, 21), at: Self.amsterdam, calendar: Self.calendar))
        #expect(abs(Self.minutesAfterMidnight(summer.sunrise) - (5 * 60 + 18)) <= 3)
        #expect(abs(Self.minutesAfterMidnight(summer.sunset) - (22 * 60 + 6)) <= 3)

        let winter = try #require(SunTimes(on: Self.date(2026, 12, 21), at: Self.amsterdam, calendar: Self.calendar))
        #expect(abs(Self.minutesAfterMidnight(winter.sunrise) - (8 * 60 + 48)) <= 3)
        #expect(abs(Self.minutesAfterMidnight(winter.sunset) - (16 * 60 + 29)) <= 3)
    }

    @Test func noSunTimesDuringPolarNight() {
        let svalbard = Coordinate(latitude: 78.2, longitude: 15.6)
        #expect(SunTimes(on: Self.date(2026, 12, 21), at: svalbard, calendar: Self.calendar) == nil)
    }

    static let day = Preset(name: "Day", level: 60)
    static let night = Preset(name: "Night", level: -20)

    static func timeSchedule(transition: Int = 30) -> BrightnessSchedule {
        BrightnessSchedule(isEnabled: true, entries: [
            ScheduleEntry(trigger: .time, minutes: 8 * 60, presetID: day.id),
            ScheduleEntry(trigger: .time, minutes: 22 * 60, presetID: night.id),
        ], transitionMinutes: transition)
    }

    @Test func picksTheLatestEntryAndTheNextOne() throws {
        let state = try #require(Self.timeSchedule().state(at: Self.date(2026, 3, 10, 14), location: nil, calendar: Self.calendar))
        #expect(state.current.presetID == Self.day.id)
        #expect(state.nextAt == Self.date(2026, 3, 10, 22))
        #expect(state.progress == 1)
        #expect(state.level(from: -20, presets: [Self.day, Self.night]) == 60)
    }

    @Test func wrapsAroundMidnight() throws {
        let state = try #require(Self.timeSchedule().state(at: Self.date(2026, 3, 10, 2), location: nil, calendar: Self.calendar))
        #expect(state.current.presetID == Self.night.id)
        #expect(state.startedAt == Self.date(2026, 3, 9, 22))
        #expect(state.nextAt == Self.date(2026, 3, 10, 8))
    }

    @Test func fadesThroughTheTransition() throws {
        let state = try #require(Self.timeSchedule().state(at: Self.date(2026, 3, 10, 8, 15), location: nil, calendar: Self.calendar))
        #expect(state.progress == 0.5)
        #expect(state.previous?.presetID == Self.night.id)
        #expect(state.level(from: -20, presets: [Self.day, Self.night]) == 20)
    }

    @Test func instantTransitionJumps() throws {
        let state = try #require(Self.timeSchedule(transition: 0).state(at: Self.date(2026, 3, 10, 8, 1), location: nil, calendar: Self.calendar))
        #expect(state.level(from: -20, presets: [Self.day, Self.night]) == 60)
    }

    @Test func sunEntriesNeedALocation() throws {
        let schedule = BrightnessSchedule(isEnabled: true, entries: [
            ScheduleEntry(trigger: .sunrise, minutes: 0, presetID: Self.day.id),
            ScheduleEntry(trigger: .sunset, minutes: -30, presetID: Self.night.id),
        ])
        #expect(schedule.usesSun)
        #expect(schedule.state(at: Self.date(2026, 6, 21), location: nil, calendar: Self.calendar) == nil)

        // 30 minutes before a 22:06 sunset.
        let state = try #require(schedule.state(at: Self.date(2026, 6, 21, 21, 50), location: Self.amsterdam, calendar: Self.calendar))
        #expect(state.current.presetID == Self.night.id)
        #expect(abs(Self.minutesAfterMidnight(state.startedAt) - (21 * 60 + 36)) <= 3)
    }

    @Test func suggestedScheduleUsesNamedPresets() {
        let schedule = BrightnessSchedule.suggested(for: Preset.defaults)
        let names = schedule.entries.map { entry in Preset.defaults.first { $0.id == entry.presetID }?.name }
        #expect(names == ["Day", "Evening", "Night"])
        #expect(!schedule.isEnabled)
    }

    @Test func scheduleRoundTrips() throws {
        let schedule = Self.timeSchedule()
        let data = try JSONEncoder().encode(schedule)
        #expect(try JSONDecoder().decode(BrightnessSchedule.self, from: data) == schedule)
    }
}
