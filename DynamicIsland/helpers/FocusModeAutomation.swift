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
import AppKit
import ApplicationServices

/// Drives Focus switching through Control Center's own UI.
///
/// macOS 27 removed the private MCSSettingsClient toggle and no longer posts
/// `_NSDoNotDisturbEnabledNotification`, so this opens the Control Center
/// panel, presses the Focus module (which expands the mode rows) and then
/// *verifies each press against the usernoted assertion store* — row labels
/// are Apple's localised semantic names while the user's store may hold
/// different names, so presses that enable the wrong mode are reverted
/// immediately (self-correcting scan). Requires Accessibility permission.
enum FocusModeAutomation {
    struct Row {
        let name: String
        let element: AXUIElement
        let isOn: Bool
    }

    /// Switch to a mode, or turn focus off when both identifiers are nil.
    /// The mode is known by three names: its semantic identifier
    /// (`com.apple.focus.work`), its store UUID (`com.apple.focus.mode.…`)
    /// and the user-visible display name; the assertion store may report any
    /// of the first two, so verification accepts either.
    static func select(modeIdentifier: String?, modeUUID: String?, displayName: String?,
                       moduleName: String? = nil) -> Bool {
        // Driving Control Center moves the pointer to the menu bar; put it
        // back where the user left it once the panel is done.
        let originalCursor = CGEvent(source: nil)?.location
        guard openControlCenter() else { NSLog("AtollFocus: openControlCenter failed"); return false }
        NSLog("AtollFocus: panel opened, windows=%d", controlCenterWindows().count)
        defer {
            closePanel()
            if let originalCursor { CGWarpMouseCursorPosition(originalCursor) }
        }
        // When a Focus mode is active the module is labelled with that
        // mode's name ("Sleep"), not "Focus"; try both.
        var moduleElement: AXUIElement?
        var moduleLabel = "Focus"
        if let found = findCheckbox(named: "Focus") {
            moduleElement = found
        } else if let moduleName, let found = findCheckbox(named: moduleName) {
            moduleElement = found
            moduleLabel = moduleName
        }
        guard let focus = moduleElement else {
            NSLog("AtollFocus: Focus module missing (tried Focus/%@)", moduleName ?? "-")
            return false
        }
        NSLog("AtollFocus: module=%@ value=%d", moduleLabel,
              (attr(focus, kAXValueAttribute as String) as? Int) ?? -1)
        clickRow(focus) // expand the mode list
        Thread.sleep(forTimeInterval: 0.5)
        let rows = modeRows()
        NSLog("AtollFocus: mode rows=%@", rows.map { "\($0.name)=\($0.isOn ? 1 : 0)" }.joined(separator: "|"))
        guard !rows.isEmpty else { NSLog("AtollFocus: no mode rows"); return false }

        let candidates = [modeIdentifier, modeUUID].compactMap { $0 }

        // Fast path: exact display-name row. The row's own AX value is the
        // fastest confirmation; the assertion store can lag behind it (and
        // may key modes by UUID rather than the semantic identifier).
        if let displayName, !candidates.isEmpty,
           let hit = rows.first(where: { $0.name == displayName }) {
            NSLog("AtollFocus: clicking row %@", hit.name)
            clickRow(hit)
            // No revert here: a name match is unambiguous, and clicking the
            // row again would undo a switch that simply took a moment to be
            // confirmed.
            let rowOK = waitForRowOn(hit, timeout: 1.2)
            NSLog("AtollFocus: row on=%@ assertions=%@", rowOK ? "yes" : "no",
                  activeAssertions().joined(separator: ","))
            return rowOK || waitFor(assertions: candidates, timeout: 1.5)
        }

        if candidates.isEmpty {
            // Turn everything off: press the Focus mode rows that read as on
            // - never the other Control Center toggles (Wi-Fi, Bluetooth…).
            // Only ever click once: a second click would switch the mode
            // back on when the assertion store is just slow to update.
            let activeRows = modeRows().filter { $0.isOn }
            NSLog("AtollFocus: turning off, active rows=%@",
                  activeRows.map(\.name).joined(separator: ","))
            for row in activeRows {
                clickRow(row.element)
                if waitForRowOff(row, timeout: 2.0) || waitFor(assertions: [], timeout: 2.5) {
                    return true
                }
            }
            NSLog("AtollFocus: off failed, assertions=%@",
                  activeAssertions().joined(separator: ","))
            return activeAssertions().isEmpty
        }

        for row in modeRows() where !row.isOn {
            let before = activeAssertions()
            clickRow(row)
            if waitFor(assertions: candidates, timeout: 1.2) { return true }
            let now = activeAssertions()
            if now != before, !now.isEmpty {
                clickRow(row) // enabled the wrong mode: revert
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        return false
    }

    /// The clicked row flips its own AX value immediately; waiting on it
    /// avoids a false negative when the assertion JSON write is slow.
    private static func waitForRowOn(_ row: Row, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (attr(row.element, kAXValueAttribute as String) as? Int) == 1 { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func waitForRowOff(_ row: Row, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if (attr(row.element, kAXValueAttribute as String) as? Int) == 0 { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    /// Only the rows the Focus module expands to, never the main toggles.
    private static func modeRows() -> [Row] {
        checkboxRows().filter { row in
            !row.name.hasPrefix("Wi‑Fi") && !row.name.hasPrefix("Wi-Fi")
                && !row.name.hasPrefix("Bluetooth") && !row.name.hasPrefix("AirDrop")
                && !["Focus", "Dark Mode", "Night Shift", "Stage Manager",
                     "Screen Mirroring", "Airplay Audio", "Record Screen",
                     "Recognise Music", "Recognize Music"].contains(row.name)
        }
    }

    // MARK: Panel lifecycle

    private static func menuBarItem(identifier: String) -> AXUIElement? {
        guard let agent = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == "MenuBarAgent"
        }) else { return nil }
        let appEl = AXUIElementCreateApplication(agent.processIdentifier)
        var out: AXUIElement?
        func walk(_ e: AXUIElement, _ d: Int) {
            if out != nil || d > 7 { return }
            for c in children(of: e) {
                if attr(c, "AXIdentifier") as? String == identifier { out = c; return }
                walk(c, d + 1)
            }
        }
        walk(appEl, 0)
        return out
    }

    @discardableResult
    private static func openControlCenter() -> Bool {
        guard let item = menuBarItem(identifier: "com.apple.menuextra.controlcenter") else { return false }
        click(elementCenter(item))
        let deadline = Date().addingTimeInterval(2.0)
        while Date() < deadline {
            if !controlCenterWindows().isEmpty { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    private static func closePanel() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let esc: CGKeyCode = 53
        CGEvent(keyboardEventSource: source, virtualKey: esc, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: esc, keyDown: false)?.post(tap: .cghidEventTap)
    }

    // MARK: Row discovery

    private static func controlCenterWindows() -> [AXUIElement] {
        guard let cc = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.controlcenter"
        }) else { return [] }
        let appEl = AXUIElementCreateApplication(cc.processIdentifier)
        return (attr(appEl, kAXWindowsAttribute as String) as? [AXUIElement]) ?? []
    }

    private static func checkboxRows() -> [Row] {
        var rows: [Row] = []
        for window in controlCenterWindows() {
            walk(window) { el in
                guard attr(el, kAXRoleAttribute as String) as? String == "AXCheckBox" else { return }
                // AX descriptions wrap some labels ("Screen\nMirroring");
                // normalise so filtering and name matching are reliable.
                let raw = (attr(el, "AXDescription") as? String) ?? ""
                let name = raw
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                let on = (attr(el, kAXValueAttribute as String) as? Int) == 1
                rows.append(Row(name: name, element: el, isOn: on))
            }
        }
        return rows
    }

    private static func findCheckbox(named name: String) -> AXUIElement? {
        checkboxRows().first(where: { $0.name == name })?.element
    }

    private static func clickRow(_ row: Row) { clickRow(row.element) }

    private static func clickRow(_ element: AXUIElement) {
        // AXPress expands the Focus module but does not toggle mode rows on
        // macOS 27; a real HID click works for both.
        click(elementCenter(element))
    }

    // MARK: Assertion verification

    private static func activeAssertions() -> [String] {
        FocusAssertionMonitor.readActiveIdentifiers()
    }

    private static func waitFor(assertions expected: [String], timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let now = activeAssertions()
            if Set(now) == Set(expected) { return true }
            // Co-active modes: any expected identifier is enough.
            if !expected.isEmpty, expected.contains(where: now.contains) { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }

    // MARK: AX helpers

    private static func attr(_ e: AXUIElement, _ n: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
    }

    private static func children(of e: AXUIElement) -> [AXUIElement] {
        (attr(e, kAXChildrenAttribute as String) as? [AXUIElement]) ?? []
    }

    private static func walk(_ e: AXUIElement, depth: Int = 0, _ body: (AXUIElement) -> Void) {
        if depth > 8 { return }
        for c in children(of: e) {
            body(c)
            walk(c, depth: depth + 1, body)
        }
    }

    private static func elementCenter(_ e: AXUIElement) -> CGPoint {
        var pos: CGPoint = .zero
        var size: CGSize = .zero
        if let pv = attr(e, kAXPositionAttribute as String) {
            AXValueGetValue(pv as! AXValue, .cgPoint, &pos)
        }
        if let sv = attr(e, kAXSizeAttribute as String) {
            AXValueGetValue(sv as! AXValue, .cgSize, &size)
        }
        return CGPoint(x: pos.x + size.width / 2, y: pos.y + size.height / 2)
    }

    private static func click(_ point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        CGEvent(mouseEventSource: source, mouseType: .leftMouseDown,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
        usleep(60_000)
        CGEvent(mouseEventSource: source, mouseType: .leftMouseUp,
                mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    }
}
#endif
