/*
 * IslandBoard (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import XCTest
@testable import IslandBoard

final class CalendarTests: XCTestCase {

    func testDefaultStartOnTodaySnapsUpToNextHour() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 14, minute: 5, second: 30))!
        let start = NewEventPopover.defaultStartDate(for: now, now: now)
        XCTAssertEqual(start, calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 15))!)
    }

    func testDefaultStartOnTodayAtExactHourGoesForwardNotStays() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 14))!
        let start = NewEventPopover.defaultStartDate(for: now, now: now)
        XCTAssertGreaterThan(start, now)
    }

    func testDefaultStartOnAnotherDayIsNineAM() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8, hour: 23, minute: 30))!
        let otherDay = calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 16))!
        let start = NewEventPopover.defaultStartDate(for: otherDay, now: now)
        XCTAssertEqual(start, calendar.date(from: DateComponents(year: 2026, month: 11, day: 21, hour: 9))!)
    }

    func testDurationLabels() {
        XCTAssertEqual(NewEventPopover.durationLabel(minutes: 15), "15 minutes")
        XCTAssertEqual(NewEventPopover.durationLabel(minutes: 60), "1 hour")
        XCTAssertEqual(NewEventPopover.durationLabel(minutes: 180), "3 hours")
    }

    // MARK: - Home weather forecast

    private func hourForecast(_ date: Date, _ temperature: Double = 20) -> LockScreenWeatherSnapshot.HourlyForecast {
        LockScreenWeatherSnapshot.HourlyForecast(
            date: date,
            temperature: temperature,
            symbolName: "sun.max.fill",
            precipitationProbability: nil
        )
    }

    private func dayForecast(_ date: Date, _ maximum: Double = 28, _ minimum: Double = 18) -> LockScreenWeatherSnapshot.DailyForecast {
        LockScreenWeatherSnapshot.DailyForecast(
            date: date,
            minimum: minimum,
            maximum: maximum,
            symbolName: "cloud.sun.fill",
            precipitationProbability: nil
        )
    }

    func testHomeWeatherUpcomingHoursIncludeCurrentHourAndLimit() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 10, minute: 57))!
        let hourStart = calendar.dateInterval(of: .hour, for: now)!.start
        let hours = (-2..<6).map { offset in
            hourForecast(calendar.date(byAdding: .hour, value: offset, to: hourStart)!)
        }

        let result = HomeWeatherForecast.upcomingHours(hours, now: now, limit: 5)
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result.first?.date, hourStart)
        XCTAssertEqual(result.last?.date, calendar.date(byAdding: .hour, value: 4, to: hourStart)!)
    }

    func testHomeWeatherUpcomingDaysIncludeTodayAndLimit() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 10, minute: 57))!
        let today = calendar.startOfDay(for: now)
        let days = (-1..<6).map { offset in
            dayForecast(calendar.date(byAdding: .day, value: offset, to: today)!)
        }

        let result = HomeWeatherForecast.upcomingDays(days, now: now, limit: 5)
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result.first?.date, today)
        XCTAssertEqual(result.last?.date, calendar.date(byAdding: .day, value: 4, to: today)!)
    }

    func testHomeWeatherEmptyAndZeroLimit() {
        XCTAssertTrue(HomeWeatherForecast.upcomingHours([], now: Date(), limit: 5).isEmpty)
        XCTAssertTrue(HomeWeatherForecast.upcomingDays([], now: Date(), limit: 5).isEmpty)
        XCTAssertTrue(HomeWeatherForecast.upcomingHours([hourForecast(Date())], now: Date(), limit: 0).isEmpty)
    }


    func testHomeWeatherFutureDaysStartTomorrow() {
        let calendar = Calendar.current
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 10, minute: 57))!
        let today = calendar.startOfDay(for: now)
        let days = (0..<7).map { offset in
            dayForecast(calendar.date(byAdding: .day, value: offset, to: today)!)
        }

        let result = HomeWeatherForecast.futureDays(days, now: now, limit: 5)
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(result.first?.date, calendar.date(byAdding: .day, value: 1, to: today)!)
        XCTAssertEqual(result.last?.date, calendar.date(byAdding: .day, value: 5, to: today)!)
    }


}
