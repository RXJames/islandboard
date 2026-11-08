/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import XCTest
@testable import Atoll

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
}
