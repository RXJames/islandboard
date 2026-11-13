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
import AppKit
import Combine
import CoreWLAN
import ObjectiveC.runtime

/// A Focus mode from the user's configuration store.
struct FocusModeInfo: Identifiable, Hashable {
    let identifier: String
    let semanticID: String
    let name: String
    let symbol: String
    let isDefault: Bool
    var id: String { identifier }
}

/// Live state + actions for every Control Center tile. Polls what has no
/// notification (Wi-Fi power, Night Shift) at 2 s and mirrors the
/// controllers the app already runs (volume, brightness, keyboard, focus)
/// through their existing notifications.
@MainActor
final class ControlCenterState: ObservableObject {
    static let shared = ControlCenterState()

    // MARK: Published state
    @Published private(set) var wifiOn = false
    @Published private(set) var wifiName: String?
    @Published private(set) var focusOn = false
    @Published private(set) var focusName: String?
    /// UUID/identifier of the active mode (mirrored from the DND monitor).
    @Published private(set) var focusIdentifier: String?
    /// User's configured Focus modes (from ModeConfigurations.json); the
    /// tile tap opens these as a picker like Control Center's own menu.
    @Published private(set) var focusModes: [FocusModeInfo] = []
    /// True when the Focus database is unreadable (missing Full Disk Access);
    /// the tile and picker explain this instead of silently doing nothing.
    @Published private(set) var focusNeedsPermission = false
    @Published private(set) var nightShiftOn = false
    @Published private(set) var nightShiftAvailable = false
    @Published private(set) var darkModeOn = false
    @Published private(set) var volume: Float = 0
    @Published private(set) var volumeMuted = false
    @Published private(set) var brightness: Float = 0
    @Published private(set) var keyboardLevel: Float = 0
    /// Set while a tile is being dragged (reorder) or resized (corner grip).
    /// The notch hover-exit auto-close consults it so a manipulation is
    /// never interrupted by the panel closing; both gesture paths clear it
    /// onEnded *and* onCancelled.
    var isInteracting = false
    /// Set after an action fails (e.g. Focus needs Automation permission).
    @Published var lastError: String?

    private var pollTimer: Timer?
    private var cancellables = Set<AnyCancellable>()
    private var started = false
    /// Levels to restore when tapping a slider tile "off".
    private var lastBrightness: Float = 0.5
    private var lastKeyboard: Float = 0.5

    private let wifiClient = CWWiFiClient.shared()
    /// CBBlueLightClient lives in CoreBrightness (private framework). The
    /// bundle is loaded at runtime and both methods are dispatched through
    /// the ObjC runtime: a typed reference would emit a link-time class
    /// symbol the linker cannot resolve against an unlinked framework.
    private lazy var blueLight: AnyObject? = {
        for path in ["/System/Library/PrivateFrameworks/CoreBrightness.framework",
                     "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"]
        where Bundle(path: path)?.load() == true { break }
        guard let cls = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        return cls.init()
    }()

    func start() {
        guard !started else { return }
        started = true

        SystemVolumeController.shared.start()
        SystemBrightnessController.shared.start()
        SystemKeyboardBacklightController.shared.start()
        DoNotDisturbManager.shared.startMonitoring()
        FocusAssertionMonitor.shared.start()
        reloadFocusModes()

        volume = SystemVolumeController.shared.currentVolume
        volumeMuted = SystemVolumeController.shared.isMuted
        brightness = SystemBrightnessController.shared.currentBrightness
        keyboardLevel = SystemKeyboardBacklightController.shared.currentLevel
        if brightness > 0 { lastBrightness = brightness }
        if keyboardLevel > 0 { lastKeyboard = keyboardLevel }

        NotificationCenter.default.publisher(for: .systemVolumeDidChange)
            .compactMap { $0.userInfo }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] info in
                self?.volume = (info["value"] as? Float) ?? self?.volume ?? 0
                self?.volumeMuted = (info["muted"] as? Bool) ?? false
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .systemBrightnessDidChange)
            .compactMap { $0.userInfo?["value"] as? Float }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.brightness = value
                if value > 0 { self?.lastBrightness = value }
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: .keyboardBacklightDidChange)
            .compactMap { $0.userInfo?["value"] as? Float }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.keyboardLevel = value
                if value > 0 { self?.lastKeyboard = value }
            }
            .store(in: &cancellables)

        // Focus: mirror the usernoted assertion store (the distributed
        // notifications DoNotDisturbManager listens for stopped firing on
        // macOS 27; assertions.json is written on every live change).
        FocusAssertionMonitor.shared.$activeIdentifiers
            .receive(on: DispatchQueue.main)
            .map { !$0.isEmpty }
            .assign(to: \.focusOn, on: self)
            .store(in: &cancellables)
        FocusAssertionMonitor.shared.$activeIdentifiers
            .receive(on: DispatchQueue.main)
            .map { $0.first }
            .assign(to: \.focusIdentifier, on: self)
            .store(in: &cancellables)
        FocusAssertionMonitor.shared.$activeName
            .receive(on: DispatchQueue.main)
            .assign(to: \.focusName, on: self)
            .store(in: &cancellables)
        FocusAssertionMonitor.shared.$accessDenied
            .receive(on: DispatchQueue.main)
            .assign(to: \.focusNeedsPermission, on: self)
            .store(in: &cancellables)

        // Dark mode flips broadcast system-wide.
        DistributedNotificationCenter.Publisher(center: DistributedNotificationCenter.default(),
                                                name: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                object: nil)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshDarkMode() }
            .store(in: &cancellables)

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPolledState() }
        }
        // Polling does not need to be punctual; tolerance lets the system
        // coalesce this wake-up with others and keep the CPU idle longer.
        pollTimer?.tolerance = 2.0 * 0.2
        refreshPolledState()
    }

    // MARK: Polling

    private func refreshPolledState() {
        let interface = wifiClient.interface()
        let on = interface?.powerOn() ?? false
        if on != wifiOn { wifiOn = on }
        let name = interface?.ssid()
        if name != wifiName { wifiName = name }
        refreshDarkMode()
        refreshNightShift()
    }

    private func refreshDarkMode() {
        let value = CFPreferencesCopyValue("AppleInterfaceStyle" as CFString,
                                           kCFPreferencesAnyApplication,
                                           kCFPreferencesCurrentUser,
                                           kCFPreferencesAnyHost) as? String
        let on = value == "Dark"
        if on != darkModeOn { darkModeOn = on }
    }

    /// Night Shift through CoreBrightness' `CBBlueLightClient`. macOS 27
    /// exposes `getBlueLightStatus:` (a C struct, not a dictionary) plus
    /// `setEnabled:`; the older `getStatus:` / `setEnable:` selectors are
    /// gone, so both are resolved defensively and the tile is marked
    /// unavailable when neither is present.
    private func refreshNightShift() {
        guard let client = blueLight else {
            nightShiftAvailable = false
            return
        }
        let sel = NSSelectorFromString("getBlueLightStatus:")
        guard let method = class_getInstanceMethod(object_getClass(client), sel) else {
            nightShiftAvailable = false
            return
        }
        nightShiftAvailable = true
        typealias GetStatusFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> ObjCBool
        let fn = unsafeBitCast(method_getImplementation(method), to: GetStatusFn.self)
        // CBBlueLightStatus is a small C struct whose tail is version
        // specific, so read the flags out of a zeroed buffer instead of
        // mirroring it. Byte 0 is the feature/schedule flag (it stays set);
        // byte 1 is the live "Night Shift is applied" bit that setEnabled:
        // flips, which is what the tile must show.
        var status = [UInt8](repeating: 0, count: 512)
        let ok = status.withUnsafeMutableBytes { raw in
            fn(client, sel, raw.baseAddress!)
        }
        guard ok.boolValue else { return }
        let on = status[1] != 0
        if on != nightShiftOn { nightShiftOn = on }
    }

    // MARK: Actions

    func toggleWiFi() {
        guard let interface = wifiClient.interface() else {
            lastError = "No Wi-Fi interface found"
            return
        }
        let target = !wifiOn
        wifiOn = target // optimistic; reverted on failure
        Task.detached(priority: .userInitiated) {
            do {
                _ = try interface.setPower(target)
            } catch {
                await MainActor.run {
                    self.wifiOn = !target
                    self.lastError = "Wi-Fi toggle failed"
                }
            }
        }
    }

    /// Parse the user's Focus modes the same way Control Center does:
    /// `~/Library/DoNotDisturb/DB/ModeConfigurations.json`.
    func reloadFocusModes() {
        Task.detached(priority: .utility) {
            let parsed = Self.parseFocusModes()
            await MainActor.run { self.focusModes = parsed }
        }
    }

    nonisolated private static func parseFocusModes() -> [FocusModeInfo] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/ModeConfigurations.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["data"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        var modes: [FocusModeInfo] = []
        for section in sections {
            guard let configs = section["modeConfigurations"] as? [String: Any] else { continue }
            for (_, value) in configs {
                guard let entry = value as? [String: Any],
                      let mode = entry["mode"] as? [String: Any],
                      let identifier = mode["identifier"] as? String,
                      let name = mode["name"] as? String,
                      !seen.contains(identifier) else { continue }
                let modeIdentifier = mode["modeIdentifier"] as? String ?? ""
                // Sleep focus is not something this tile should toggle.
                if modeIdentifier.contains("sleep") { continue }
                seen.insert(identifier)
                modes.append(FocusModeInfo(
                    identifier: identifier,
                    semanticID: modeIdentifier,
                    name: name,
                    symbol: mode["symbolImageName"] as? String ?? "moon.fill",
                    isDefault: modeIdentifier == "com.apple.donotdisturb.mode.default"
                ))
            }
        }
        // Control Center lists Do Not Disturb first, then the user's modes.
        return modes.sorted { a, b in
            if a.isDefault != b.isDefault { return a.isDefault }
            return a.name < b.name
        }
    }

    func toggleFocus() {
        if focusOn {
            turnFocusOff()
        } else if let first = focusModes.first {
            selectFocusMode(first)
        } else {
            lastError = "No Focus modes found"
        }
    }

    /// Switch to (or off) a mode through Control Center's Focus rows,
    /// verifying against the assertion store; falls back to opening Focus
    /// settings if the automation cannot reach the daemon.
    func selectFocusMode(_ mode: FocusModeInfo) {
        runFocusAutomation(modeIdentifier: mode.semanticID,
                           modeUUID: mode.identifier,
                           displayName: mode.name,
                           moduleName: focusName)
    }

    func turnFocusOff() {
        guard focusOn else { return }
        runFocusAutomation(modeIdentifier: nil, modeUUID: nil, displayName: nil,
                           moduleName: focusName)
    }

    /// Accepts the Full Disk Access prompt: opens the privacy pane so the
    /// user can add IslandBoard once; the monitor picks the access up on its next
    /// poll without a relaunch.
    func requestFocusPermission() {
        lastError = "Focus needs Full Disk Access"
        FullDiskAccessPermissionStore.shared.openSystemSettings()
    }

    private func runFocusAutomation(modeIdentifier: String?, modeUUID: String?,
                                    displayName: String?, moduleName: String?) {
        // The permission may have been granted since launch; re-check live
        // instead of trusting the cached value.
        let accessibility = AccessibilityPermissionStore.shared
        accessibility.refreshStatus()
        guard accessibility.isAuthorized else {
            lastError = "Focus switching needs Accessibility access"
            accessibility.openSystemSettings()
            return
        }
        // The automation clicks the menu bar, which moves the pointer out of
        // the notch; veto the hover-exit close for its whole duration.
        let wasInteracting = isInteracting
        isInteracting = true
        Task.detached(priority: .userInitiated) {
            let ok = FocusModeAutomation.select(modeIdentifier: modeIdentifier,
                                                modeUUID: modeUUID,
                                                displayName: displayName,
                                                moduleName: moduleName)
            await MainActor.run { self.isInteracting = wasInteracting }
            if !ok {
                // A toast, not a Settings jump: the switch may still have
                // landed, and the manual fallback is only a click away.
                await MainActor.run { self.lastError = "Could not switch Focus modes" }
            }
        }
    }

    /// One tap flips Night Shift through `setEnabled:`; the state is verified
    /// right after (and again by the 2 s poll) so the tile never lies.
    func toggleNightShift() {
        guard nightShiftAvailable, let client = blueLight,
              let method = class_getInstanceMethod(object_getClass(client),
                                                   NSSelectorFromString("setEnabled:"))
        else {
            lastError = "Night Shift unavailable"
            return
        }
        let target = !nightShiftOn
        nightShiftOn = target
        typealias SetEnabledFn = @convention(c) (AnyObject, Selector, ObjCBool) -> Void
        let fn = unsafeBitCast(method_getImplementation(method), to: SetEnabledFn.self)
        fn(client, NSSelectorFromString("setEnabled:"), ObjCBool(target))
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self else { return }
            self.refreshNightShift()
            if self.nightShiftOn != target {
                self.lastError = "Night Shift did not change"
            }
        }
    }

    func toggleDarkMode() {
        let script = """
        tell application "System Events"
            tell appearance preferences
                set dark mode to not dark mode
            end tell
        end tell
        """
        Task.detached(priority: .userInitiated) {
            do {
                _ = try AppleScriptRunner.run(script: script)
            } catch {
                await MainActor.run {
                    self.lastError = "Dark Mode needs System Events permission"
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Appearance-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    func toggleMute() {
        SystemVolumeController.shared.toggleMute()
    }

    func setVolume(_ value: Float) {
        SystemVolumeController.shared.setVolume(value)
    }

    func setBrightness(_ value: Float) {
        SystemBrightnessController.shared.setBrightness(value)
    }

    func setKeyboard(_ value: Float) {
        SystemKeyboardBacklightController.shared.setLevel(value)
    }

    /// Tap on a slider tile: mute/off, or restore the previous level.
    func tapSlider(_ kind: ControlTileKind) {
        switch kind {
        case .volume:
            toggleMute()
        case .brightness:
            SystemBrightnessController.shared.setBrightness(brightness > 0.02 ? 0 : lastBrightness)
        case .keyboard:
            SystemKeyboardBacklightController.shared.setLevel(keyboardLevel > 0.02 ? 0 : lastKeyboard)
        default:
            break
        }
    }

    func toggle(_ kind: ControlTileKind) {
        switch kind {
        case .wifi: toggleWiFi()
        case .focus: toggleFocus()
        case .nightShift: toggleNightShift()
        case .darkMode: toggleDarkMode()
        case .volume, .brightness, .keyboard: tapSlider(kind)
        }
    }

    func isOn(_ kind: ControlTileKind) -> Bool {
        switch kind {
        case .wifi: return wifiOn
        case .focus: return focusOn
        case .nightShift: return nightShiftOn
        case .darkMode: return darkModeOn
        case .volume: return !volumeMuted
        case .brightness: return brightness > 0.02
        case .keyboard: return keyboardLevel > 0.02
        }
    }

    func level(_ kind: ControlTileKind) -> Float? {
        switch kind {
        case .volume: return volume
        case .brightness: return brightness
        case .keyboard: return keyboardLevel
        default: return nil
        }
    }
}
