/*
 * IslandBoard (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import SwiftUI
import Defaults
import Foundation

/// Picks the five-hour / five-day slices out of the raw Open-Meteo arrays.
/// Kept separate from the view so date filtering, time zones and the
/// "today only" vs "today + next 5 days" split are testable without SwiftUI.
enum HomeWeatherForecast {
    static func upcomingHours(
        _ hours: [LockScreenWeatherSnapshot.HourlyForecast],
        now: Date = Date(),
        timeZone: TimeZone? = nil,
        limit: Int = 5
    ) -> [LockScreenWeatherSnapshot.HourlyForecast] {
        guard limit > 0 else { return [] }
        let calendar = forecastCalendar(timeZone)
        let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        var seen = Set<Date>()
        return hours
            .filter { $0.date >= currentHour && seen.insert($0.date).inserted }
            .sorted { $0.date < $1.date }
            .prefix(limit)
            .map { $0 }
    }

    /// Today plus the following days. Kept for callers that want an inclusive
    /// list; the Home strip uses `futureDays` because today is already the
    /// single-day header.
    static func upcomingDays(
        _ days: [LockScreenWeatherSnapshot.DailyForecast],
        now: Date = Date(),
        timeZone: TimeZone? = nil,
        limit: Int = 5
    ) -> [LockScreenWeatherSnapshot.DailyForecast] {
        guard limit > 0 else { return [] }
        let calendar = forecastCalendar(timeZone)
        let today = calendar.startOfDay(for: now)
        var seen = Set<Date>()
        return days
            .filter { $0.date >= today && seen.insert($0.date).inserted }
            .sorted { $0.date < $1.date }
            .prefix(limit)
            .map { $0 }
    }

    /// The five days shown next to the single-day header: tomorrow onwards.
    static func futureDays(
        _ days: [LockScreenWeatherSnapshot.DailyForecast],
        now: Date = Date(),
        timeZone: TimeZone? = nil,
        limit: Int = 5
    ) -> [LockScreenWeatherSnapshot.DailyForecast] {
        guard limit > 0 else { return [] }
        let calendar = forecastCalendar(timeZone)
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return [] }
        var seen = Set<Date>()
        return days
            .filter { $0.date >= tomorrow && seen.insert($0.date).inserted }
            .sorted { $0.date < $1.date }
            .prefix(limit)
            .map { $0 }
    }

    private static func forecastCalendar(_ timeZone: TimeZone?) -> Calendar {
        var calendar = Calendar.current
        if let timeZone {
            calendar.timeZone = timeZone
        }
        return calendar
    }
}

/// Five-hour (+ optional five-day) forecast beneath the Home calendar.
/// The compact dimensions are deliberate: the calendar keeps its 120pt panel
/// and the Home tab keeps its 200pt height. Weather is an independent feature
/// and is not shown at all when its own toggle is off.
struct NotchHomeWeatherStrip: View {
    @ObservedObject private var weather = LockScreenWeatherManager.shared
    @Default(.homeWeatherLocationMode) private var locationMode
    @Default(.homeWeatherCityName) private var cityName
    @Default(.homeWeatherDisplayMode) private var displayMode

    private var snapshot: LockScreenWeatherSnapshot? { weather.homeSnapshot }

    private var isForecastUnavailable: Bool {
        snapshot == nil || hours.isEmpty
    }

    private var forecastTimeZone: TimeZone? {
        snapshot?.forecastTimeZoneIdentifier.flatMap(TimeZone.init(identifier:))
    }

    private var hours: [LockScreenWeatherSnapshot.HourlyForecast] {
        HomeWeatherForecast.upcomingHours(
            snapshot?.hourlyForecast ?? [],
            timeZone: forecastTimeZone
        )
    }

    private var futureDays: [LockScreenWeatherSnapshot.DailyForecast] {
        HomeWeatherForecast.futureDays(
            snapshot?.dailyForecast ?? [],
            timeZone: forecastTimeZone
        )
    }

    private var todayForecast: LockScreenWeatherSnapshot.DailyForecast? {
        guard let snapshot else { return nil }
        var calendar = Calendar.current
        if let forecastTimeZone { calendar.timeZone = forecastTimeZone }
        return snapshot.dailyForecast.first {
            calendar.isDate($0.date, inSameDayAs: Date())
        }
    }

    var body: some View {
        Group {
            if let snapshot, !hours.isEmpty {
                forecast(snapshot)
            } else {
                unavailable
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color.white.opacity(0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 0.5)
        )
        .onAppear {
            Task {
                _ = await weather.refreshHomeWeather()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isForecastUnavailable {
                SettingsWindowController.shared.showWeatherSettings()
            } else {
                openSystemWeather()
            }
        }
        .help(isForecastUnavailable ? "Open Weather settings" : "Open Weather")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isForecastUnavailable ? "Home weather unavailable. Open Weather settings" : "Home weather forecast. Open Weather")
        .accessibilityAddTraits(.isButton)
    }

    /// Brings up the system Weather app. It ships with macOS 13+, but the
    /// user can remove it, so fall back to the app's own Weather settings
    /// rather than doing nothing on a click.
    private func openSystemWeather() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.weather") else {
            SettingsWindowController.shared.showWeatherSettings()
            return
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    private func forecast(_ snapshot: LockScreenWeatherSnapshot) -> some View {
        GeometryReader { geometry in
            // One uniform transform is applied to the whole block. As the
            // calendar expands (or the notch is resized), every glyph, icon and
            // row scales/moves together instead of each Text animating its own
            // font metrics. The tight base spacing also removes the wide gaps
            // between the current, hourly and five-day rows.
            let singleDay = displayMode == .todayOnly
            let baseWidth: CGFloat = 340
            let baseHeight: CGFloat = singleDay ? 72 : 78
            let availableWidth = max(1, geometry.size.width - 12)
            let availableHeight = max(1, geometry.size.height - 4)
            let widthScale = availableWidth / baseWidth
            let heightScale = availableHeight / baseHeight

            // Scale with both dimensions, but never past the height that is
            // actually available. A uniform transform keeps every glyph in a
            // row moving together while the calendar hover animation shrinks
            // the card. Layout width is divided by the scale so the content
            // continues to fill the card instead of leaving side margins.
            let geometricScale = sqrt(max(widthScale, 0.01) * max(heightScale, 0.01))
            let scale = min(max(geometricScale, 0.55), 1.6, heightScale)
            let layoutWidth = max(1, availableWidth / scale)

            VStack(spacing: 2) {
                header(snapshot, showsTodayRange: true)
                hourlyRow(expanded: singleDay)
                if !singleDay {
                    dailyRow
                }
            }
            .frame(width: layoutWidth, height: baseHeight)
            .scaleEffect(scale)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }

    private var unavailable: some View {
        HStack(spacing: 6) {
            Image(systemName: "location.slash")
                .font(.system(size: 10, weight: .semibold))
            Text(unavailableText)
                .font(.system(size: 9, weight: .medium))
            Spacer(minLength: 0)
            Image(systemName: "gearshape")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.4))
        }
        .foregroundStyle(Color.white.opacity(0.55))
        .padding(.horizontal, 8)
    }

    private var unavailableText: String {
        if locationMode == .city && cityName.isEmpty {
            return "Choose a city in Settings"
        }
        return "Weather unavailable"
    }

    private func header(_ snapshot: LockScreenWeatherSnapshot, showsTodayRange: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: snapshot.symbolName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.92))

            if let temperature = snapshot.temperatureInfo?.current {
                Text("\(Int(round(temperature)))°")
                    .font(.system(size: 16, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
            }

            Text(snapshot.description)
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.58))
                .lineLimit(1)

            if showsTodayRange, let todayForecast {
                Text("H\(Int(round(todayForecast.maximum)))° L\(Int(round(todayForecast.minimum)))°")
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(Color.white.opacity(0.56))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Text(displayLocation(snapshot))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(height: 19)
    }

    private func displayLocation(_ snapshot: LockScreenWeatherSnapshot) -> String {
        if locationMode == .city, !cityName.isEmpty {
            return cityName
        }
        if let name = snapshot.locationName, !name.isEmpty {
            return name
        }
        return "Local"
    }

    private func hourlyRow(expanded: Bool) -> some View {
        HStack(spacing: 0) {
            ForEach(hours, id: \.id) { hour in
                VStack(spacing: 0) {
                    Text(hourLabel(hour))
                        .font(.system(size: expanded ? 10.5 : 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.55))
                    HStack(spacing: 1) {
                        Image(systemName: hour.symbolName)
                            .font(.system(size: expanded ? 15 : 12.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.9))
                        Text("\(Int(round(hour.temperature)))°")
                            .font(.system(size: expanded ? 15 : 12.5, weight: .medium).monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }
                .frame(maxWidth: .infinity)
                .minimumScaleFactor(0.7)
            }
        }
        .frame(height: expanded ? 51 : 27)
    }

    private var dailyRow: some View {
        HStack(spacing: 2) {
            ForEach(futureDays, id: \.id) { day in
                VStack(spacing: 0) {
                    // Weekday + icon share the top line; the high/low gets the
                    // full column width below. Putting the icon next to the
                    // temperatures made the last digit truncate at narrow notch
                    // widths.
                    HStack(spacing: 2) {
                        Text(dayLabel(day))
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.55))
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                        Image(systemName: day.symbolName)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.85))
                    }
                    Text("\(Int(round(day.minimum)))/\(Int(round(day.maximum)))")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 27)
    }

    private func hourLabel(_ hour: LockScreenWeatherSnapshot.HourlyForecast) -> String {
        var calendar = Calendar.current
        if let forecastTimeZone { calendar.timeZone = forecastTimeZone }
        if calendar.isDate(hour.date, equalTo: Date(), toGranularity: .hour) {
            return "Now"
        }
        let formatter = DateFormatter()
        formatter.timeZone = forecastTimeZone
        formatter.setLocalizedDateFormatFromTemplate("HH")
        return formatter.string(from: hour.date)
    }

    private func dayLabel(_ day: LockScreenWeatherSnapshot.DailyForecast) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = forecastTimeZone
        formatter.setLocalizedDateFormatFromTemplate("EEE")
        return formatter.string(from: day.date)
    }
}
