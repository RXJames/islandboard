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
import AppKit
import CoreLocation

/// Weather is its own settings tab, not a subset of Calendar. The Home strip
/// can be on while the calendar is off, and the chosen city only affects the
/// Home forecast (the lock-screen weather widget keeps its own configuration).
struct WeatherSettings: View {
    @Default(.enableHomeWeather) private var enableHomeWeather
    @Default(.homeWeatherLocationMode) private var locationMode
    @Default(.homeWeatherDisplayMode) private var displayMode
    @Default(.homeWeatherCityName) private var cityName
    @Default(.homeWeatherCityLatitude) private var cityLatitude
    @Default(.homeWeatherCityLongitude) private var cityLongitude

    @StateObject private var locationPermission = WeatherLocationPermissionCoordinator()
    @State private var query = ""
    @State private var results: [CitySearchResult] = []
    @State private var isSearching = false
    @State private var searchError: String?

    var body: some View {
        Form {
            Section(header: Text("Home Weather")) {
                Defaults.Toggle(key: .enableHomeWeather) {
                    Text("Show weather on Home")
                }
                .settingsHighlight(id: "weather-Show weather on Home")

                Text("Weather and Calendar are independent. When both are on, weather appears below the calendar; when the calendar is off, weather still appears in the Home right column.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if enableHomeWeather {
                Section(header: Text("Location")) {
                    Picker("Location", selection: $locationMode) {
                        ForEach(HomeWeatherLocationMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .settingsHighlight(id: "weather-Weather location")

                    if locationMode == .currentLocation {
                        Text("Uses the current location, the same permission as the lock-screen weather widget.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 12) {
                            Button("Use Current Location") {
                                LockScreenWeatherManager.shared.clearHomeWeather()
                                locationPermission.requestCurrentLocation()
                            }
                            .buttonStyle(.link)

                            Button("Open Location Settings") {
                                WeatherLocationPermissionCoordinator.openSystemLocationSettings()
                            }
                            .buttonStyle(.link)
                        }
                    } else {
                        cityPicker
                    }
                }
                .onChange(of: locationMode) { _, newMode in
                    LockScreenWeatherManager.shared.clearHomeWeather()
                    switch newMode {
                    case .currentLocation:
                        locationPermission.requestCurrentLocation()
                    case .city:
                        Task {
                            _ = await LockScreenWeatherManager.shared.refreshHomeWeather(force: true)
                        }
                    }
                }

                Section(header: Text("Display")) {
                    Picker("Forecast", selection: $displayMode) {
                        ForEach(HomeWeatherDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .settingsHighlight(id: "weather-Weather display")

                    Text(displayMode == .todayOnly
                         ? "Shows current conditions, today's high/low and the next 5 hours."
                         : "Shows current conditions, today's high/low, the next 5 hours, and tomorrow plus the following 4 days.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .navigationTitle("Weather")
        .onChange(of: enableHomeWeather) { _, enabled in
            guard enabled else {
                LockScreenWeatherManager.shared.clearHomeWeather()
                return
            }
            switch locationMode {
            case .currentLocation:
                locationPermission.requestCurrentLocation()
            case .city:
                Task {
                    _ = await LockScreenWeatherManager.shared.refreshHomeWeather(force: true)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            // Coming back from System Settings after granting location should
            // refresh the Home strip without making the user reselect the mode.
            guard enableHomeWeather, locationMode == .currentLocation else { return }
            let status = CLLocationManager.authorizationStatus()
            guard status == .authorizedAlways else { return }
            Task {
                // Let the normal 15-minute cache decide; returning from System
                // Settings should not force a new request on every activation.
                _ = await LockScreenWeatherManager.shared.refreshHomeWeather()
            }
        }
    }

    @ViewBuilder
    private var cityPicker: some View {
        if !cityName.isEmpty {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .foregroundStyle(.secondary)
                Text(cityName)
                    .lineLimit(1)
                Spacer()
                Button("Clear") {
                    clearCity()
                }
                .buttonStyle(.borderless)
            }
        }

        TextField("Search for a city", text: $query)
            .textFieldStyle(.roundedBorder)
            .task(id: query) {
                await searchCities(for: query)
            }

        if isSearching {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Searching…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let searchError {
            Text(searchError)
                .font(.caption)
                .foregroundStyle(.red)
        } else if !results.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(results) { result in
                    Button {
                        select(result)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "mappin.circle")
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.name)
                                if !result.subtitle.isEmpty {
                                    Text(result.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                }
            }
        } else if query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 {
            Text("No cities found.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if cityName.isEmpty {
            Text("Pick a city to use a fixed forecast location. Current location is not used in City mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @MainActor
    private func searchCities(for rawQuery: String) async {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 2 else {
            results = []
            searchError = nil
            isSearching = false
            return
        }

        // Debounce typing so every keystroke does not hit the geocoder.
        try? await Task.sleep(nanoseconds: 350_000_000)
        guard !Task.isCancelled else { return }

        isSearching = true
        searchError = nil
        defer { isSearching = false }

        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(encoded)&count=8&language=en&format=json")
        else {
            searchError = "Could not build the city search request."
            return
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard !Task.isCancelled else { return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                searchError = "City search failed."
                return
            }
            let payload = try JSONDecoder().decode(CitySearchResponse.self, from: data)
            results = payload.results ?? []
        } catch {
            guard !Task.isCancelled else { return }
            searchError = "City search failed. Check your connection."
        }
    }

    private func select(_ result: CitySearchResult) {
        cityName = result.displayName
        cityLatitude = result.latitude
        cityLongitude = result.longitude
        query = ""
        results = []
        searchError = nil
        // Do not keep showing the previous city's forecast while the new city
        // is being fetched.
        LockScreenWeatherManager.shared.clearHomeWeather()
        Task {
            _ = await LockScreenWeatherManager.shared.refreshHomeWeather(force: true)
        }
    }

    private func clearCity() {
        cityName = ""
        cityLatitude = 0
        cityLongitude = 0
        query = ""
        results = []
        searchError = nil
        LockScreenWeatherManager.shared.clearHomeWeather()
    }
}

private struct CitySearchResponse: Decodable {
    let results: [CitySearchResult]?
}

private struct CitySearchResult: Decodable, Identifiable {
    let id: Int
    let name: String
    let latitude: Double
    let longitude: Double
    let country: String?
    let admin1: String?

    var subtitle: String {
        [admin1, country]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != name }
            .joined(separator: ", ")
    }

    var displayName: String {
        subtitle.isEmpty ? name : "\(name), \(subtitle)"
    }
}
