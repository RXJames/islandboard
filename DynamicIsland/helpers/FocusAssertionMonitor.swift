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

#if os(macOS)
import Foundation
import Combine
import os

/// Ground truth for the active Focus mode.
///
/// macOS 27 stopped broadcasting `_NSDoNotDisturbEnabledNotification`, so the
/// distributed-notification channel `DoNotDisturbManager` listens on never
/// fires. usernoted instead persists live assertions to
/// `~/Library/DoNotDisturb/DB/Assertions.json` (atomic write = rename), which
/// we watch via the parent directory plus a coarse poll as a safety net.
@MainActor
final class FocusAssertionMonitor: ObservableObject {
    static let shared = FocusAssertionMonitor()

    /// Semantic identifiers (`com.apple.focus.work`, …) of every active mode.
    @Published private(set) var activeIdentifiers: [String] = []
    /// Display name of the primary active mode (nil when focus is off).
    @Published private(set) var activeName: String?
    /// True when the DoNotDisturb database is unreadable because the app is
    /// missing Full Disk Access. The Focus tile surfaces this instead of
    /// silently reporting "off" and doing nothing on tap.
    @Published private(set) var accessDenied = false

    private var directorySource: DispatchSourceFileSystemObject?
    private var directoryHandle: FileHandle?
    private var pollTimer: Timer?
    private var modeNames: [String: String] = [:]   // modeIdentifier -> user name
    private var started = false

    static let assertionsURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/DoNotDisturb/DB/Assertions.json")

    func start() {
        guard !started else { return }
        started = true
        reloadModeNames()
        refresh()
        watchFile()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Polling does not need to be punctual; tolerance lets the system
        // coalesce this wake-up with others and keep the CPU idle longer.
        pollTimer?.tolerance = 3 * 0.2
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        directorySource?.cancel()
        directorySource = nil
        try? directoryHandle?.close()
        directoryHandle = nil
        started = false
    }

    func refresh() {
        let snapshot = Self.readActiveIdentifiersDetailed()
        let current = snapshot.identifiers
        if snapshot.denied != accessDenied { accessDenied = snapshot.denied }
        os_log("FocusAssertion refresh: url=%{public}@ active=%{public}@ denied=%{public}@",
               log: .default, type: .debug,
               Self.assertionsURL.path, String(describing: current),
               snapshot.denied ? "yes" : "no")
        if current != activeIdentifiers {
            activeIdentifiers = current
        }
        // Names can change while focus is active (mode renamed in Settings).
        if !current.isEmpty, modeNames.isEmpty { reloadModeNames() }
        let names = modeNames
        activeName = current.lazy.compactMap { names[$0] }.first
    }

    private func reloadModeNames() {
        modeNames = Self.readModeNames()
    }

    private func watchFile() {
        let dir = Self.assertionsURL.deletingLastPathComponent()
        guard let handle = try? FileHandle(forReadingFrom: dir) else { return }
        directoryHandle = handle
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Re-arm: directory replacement (atomic write) may close our fd.
            self.refresh()
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                source.cancel()
                self.directorySource = nil
                try? self.directoryHandle?.close()
                self.directoryHandle = nil
                self.watchFile()
            }
        }
        source.resume()
        directorySource = source
    }

    // MARK: - Parsing

    /// Semantic mode identifiers of live assertions: every assertion record
    /// whose UUID has not been invalidated.
    nonisolated static func readActiveIdentifiers() -> [String] {
        readActiveIdentifiersDetailed().identifiers
    }

    /// Same read, but also distinguishes "no active assertions" from
    /// "the database is unreadable" (missing Full Disk Access), which the
    /// tile must not confuse.
    nonisolated static func readActiveIdentifiersDetailed() -> (identifiers: [String], denied: Bool) {
        do {
            let data = try Data(contentsOf: assertionsURL)
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sections = root["data"] as? [[String: Any]] else {
                os_log("FocusAssertion: JSON shape unexpected")
                return ([], false)
            }
            var invalidated = Set<String>()
            var assertions: [(uuid: String, mode: String)] = []
            for section in sections {
                for record in section["storeInvalidationRecords"] as? [[String: Any]] ?? [] {
                    if let assertion = record["invalidationAssertion"] as? [String: Any],
                       let uuid = assertion["assertionUUID"] as? String {
                        invalidated.insert(uuid)
                    }
                }
                for record in section["storeAssertionRecords"] as? [[String: Any]] ?? [] {
                    guard let uuid = record["assertionUUID"] as? String,
                          let details = record["assertionDetails"] as? [String: Any],
                          let mode = details["assertionDetailsModeIdentifier"] as? String else { continue }
                    assertions.append((uuid, mode))
                }
            }
            var live: [String] = []
            for (uuid, mode) in assertions where !invalidated.contains(uuid) {
                if !live.contains(mode) { live.append(mode) }
            }
            return (live, false)
        } catch {
            let ns = error as NSError
            let denied = (ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoPermissionError)
                || (ns.domain == NSPOSIXErrorDomain && (ns.code == EACCES || ns.code == EPERM))
            os_log("FocusAssertion: read failed %{public}@", error.localizedDescription)
            return ([], denied)
        }
    }

    /// modeIdentifier -> user-visible name from ModeConfigurations.json.
    nonisolated static func readModeNames() -> [String: String] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/DoNotDisturb/DB/ModeConfigurations.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["data"] as? [[String: Any]] else { return [:] }
        var names: [String: String] = [:]
        for section in sections {
            guard let configs = section["modeConfigurations"] as? [String: Any] else { continue }
            for (_, value) in configs {
                guard let entry = value as? [String: Any],
                      let mode = entry["mode"] as? [String: Any],
                      let modeIdentifier = mode["modeIdentifier"] as? String,
                      let name = mode["name"] as? String else { continue }
                names[modeIdentifier] = name
                // Assertions may report the store UUID instead of the
                // semantic identifier; map both to the same display name.
                if let uuid = mode["identifier"] as? String { names[uuid] = name }
            }
        }
        return names
    }
}
#endif
