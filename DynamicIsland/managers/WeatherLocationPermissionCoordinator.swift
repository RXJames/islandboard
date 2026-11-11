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

import AppKit
import Combine
import CoreLocation
import Defaults

/// Drives the explicit "use current location" action in Weather settings.
/// When macOS already denies location, go straight to System Settings. When
/// the permission is undecided, ask first; if the user denies the prompt,
/// open the exact Location Services pane so they can turn it on.
@MainActor
final class WeatherLocationPermissionCoordinator: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var awaitingDecision = false

    override init() {
        super.init()
        manager.delegate = self
    }

    func requestCurrentLocation() {
        switch CLLocationManager.authorizationStatus() {
        case .authorizedAlways:
            refreshLiveWeather()
        case .notDetermined:
            awaitingDecision = true
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            Self.openSystemLocationSettings()
        @unknown default:
            Self.openSystemLocationSettings()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.handleAuthorizationChange()
        }
    }

    private func handleAuthorizationChange() {
        guard awaitingDecision,
              Defaults[.homeWeatherLocationMode] == .currentLocation
        else {
            awaitingDecision = false
            return
        }

        switch CLLocationManager.authorizationStatus() {
        case .authorizedAlways:
            awaitingDecision = false
            refreshLiveWeather()
        case .denied, .restricted:
            awaitingDecision = false
            Self.openSystemLocationSettings()
        case .notDetermined:
            break
        @unknown default:
            awaitingDecision = false
        }
    }

    private func refreshLiveWeather() {
        Task {
            _ = await LockScreenWeatherManager.shared.refreshHomeWeather(force: true)
        }
    }

    @MainActor
    static func openSystemLocationSettings() {
        NSApp.activate(ignoringOtherApps: true)

        // Current macOS first, then the older Privacy pane URL. The final URL
        // is a safe fallback if the specific anchor changes again.
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_LocationServices",
            "x-apple.systempreferences:com.apple.preference.security"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
