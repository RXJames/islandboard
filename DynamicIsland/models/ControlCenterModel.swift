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
import Defaults

// MARK: - Tile catalogue

/// The control-center-style buttons the tab can host. Raw values are
/// persisted in `Defaults[.controlCenterLayout]`; never rename one, add a
/// new case instead.
enum ControlTileKind: String, Codable, CaseIterable, Identifiable {
    case wifi
    case focus
    case nightShift
    case darkMode
    case volume
    case brightness
    case keyboard

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .focus: return "Focus"
        case .nightShift: return "Night Shift"
        case .darkMode: return "Dark Mode"
        case .volume: return "Sound"
        case .brightness: return "Display"
        case .keyboard: return "Keyboard"
        }
    }

    /// Slider tiles (volume, brightness, keyboard) carry an inline control
    /// at large size and offer off/restore taps; the rest are on/off.
    var isSlider: Bool {
        switch self {
        case .volume, .brightness, .keyboard: return true
        case .wifi, .focus, .nightShift, .darkMode: return false
        }
    }

    func icon(on: Bool) -> String {
        switch self {
        case .wifi: return "wifi"
        case .focus: return on ? "moon.fill" : "moon"
        case .nightShift: return on ? "sun.max.fill" : "sun.max"
        case .darkMode: return on ? "moon.stars.fill" : "moon.stars"
        case .volume: return on ? "speaker.wave.2.fill" : "speaker.slash.fill"
        case .brightness: return "sun.max"
        case .keyboard: return "light.max"
        }
    }

    /// Control Center's own tint palette; users can override per tile.
    var defaultTint: Color {
        switch self {
        case .wifi: return Color(red: 0.04, green: 0.52, blue: 1.0)
        case .focus: return Color(red: 0.37, green: 0.36, blue: 0.92)
        case .nightShift: return Color(red: 1.0, green: 0.58, blue: 0.0)
        case .darkMode: return Color(red: 0.44, green: 0.44, blue: 0.46)
        case .volume: return Color(red: 1.0, green: 0.23, blue: 0.53)
        case .brightness, .keyboard: return Color(red: 0.20, green: 0.78, blue: 0.95)
        }
    }

    /// Factory layout: the three slider controls the notch is expected to
    /// replace first, each at the full width. The remaining toggles stay in
    /// the catalogue but start hidden, so Edit can bring them back.
    static let defaultLayout: [ControlTileConfig] = [
        .init(kind: .keyboard, size: .large),
        .init(kind: .volume, size: .large),
        .init(kind: .brightness, size: .large),
        .init(kind: .wifi, size: .small, visible: false),
        .init(kind: .focus, size: .small, visible: false),
        .init(kind: .nightShift, size: .small, visible: false),
        .init(kind: .darkMode, size: .small, visible: false)
    ]
}

enum ControlTileSize: Int, Codable, CaseIterable, Defaults.Serializable {
    case small = 0
    case medium = 1
    case large = 2

    /// Columns a tile occupies in the four-wide grid, mirroring the three
    /// tile sizes Control Center offers.
    var columnSpan: Int {
        switch self {
        case .small: return 1
        case .medium: return 2
        case .large: return 4
        }
    }

    var next: ControlTileSize {
        switch self {
        case .small: return .medium
        case .medium: return .large
        case .large: return .small
        }
    }

    var label: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        }
    }
}

/// One tile's user-editable state. `tintHex` overrides `defaultTint`.
struct ControlTileConfig: Codable, Hashable, Identifiable, Defaults.Serializable {
    var kind: ControlTileKind
    var size: ControlTileSize
    var visible: Bool = true
    var tintHex: String? = nil

    var id: String { kind.rawValue }
}

// MARK: - Layout store

/// Pure helpers for the persisted tile layout plus the Defaults glue. All
/// editing operations are free functions over `[ControlTileConfig]` so the
/// reorder/resize/visibility rules are unit-testable.
enum ControlCenterLayout {
    static let columns = 4

    static func load() -> [ControlTileConfig] {
        let stored = Defaults[.controlCenterLayout]
        let storedKinds = Set(stored.map(\.kind))
        var configs = stored.filter { ControlTileKind.allCases.contains($0.kind) }
        // Brand-new kinds (app upgrades) append with defaults, like TabCatalog.ordered.
        for config in ControlTileKind.defaultLayout where !storedKinds.contains(config.kind) {
            configs.append(config)
        }
        return configs.isEmpty ? ControlTileKind.defaultLayout : configs
    }

    static func save(_ configs: [ControlTileConfig]) {
        Defaults[.controlCenterLayout] = configs
    }

    static func mutate(_ body: (inout [ControlTileConfig]) -> Void) {
        var configs = load()
        body(&configs)
        save(configs)
    }

    static func index(of kind: ControlTileKind, in configs: [ControlTileConfig]) -> Int? {
        configs.firstIndex { $0.kind == kind }
    }

    static func cycleSize(kind: ControlTileKind, in configs: [ControlTileConfig]) -> [ControlTileConfig] {
        var result = configs
        guard let i = index(of: kind, in: configs) else { return result }
        result[i].size = result[i].size.next
        return result
    }

    static func setVisible(kind: ControlTileKind, _ visible: Bool, in configs: [ControlTileConfig]) -> [ControlTileConfig] {
        var result = configs
        guard let i = index(of: kind, in: configs) else { return result }
        result[i].visible = visible
        return result
    }

    static func setTint(kind: ControlTileKind, hex: String?, in configs: [ControlTileConfig]) -> [ControlTileConfig] {
        var result = configs
        guard let i = index(of: kind, in: configs) else { return result }
        result[i].tintHex = hex
        return result
    }

    /// Move `dragged` so exactly `visibleIndex` visible tiles precede it,
    /// mirroring `TabCatalog.moved`: the slot is derived from the visible
    /// flow, so the index can be computed from frozen drag-start frames and
    /// hidden tiles keep their array slots.
    static func moved(_ configs: [ControlTileConfig],
                      dragging dragged: ControlTileKind,
                      toVisibleIndex visibleIndex: Int) -> [ControlTileConfig] {
        guard let from = index(of: dragged, in: configs) else { return configs }
        var result = configs
        let moved = result.remove(at: from)
        var insertAt = result.count
        var visibleSeen = 0
        for (i, config) in result.enumerated() where config.visible {
            if visibleSeen == visibleIndex { insertAt = i; break }
            visibleSeen += 1
        }
        result.insert(moved, at: insertAt)
        return result
    }

    /// Visible configs, then packed into rows of at most 4 spans: a tile
    /// that does not fit the current row wraps to a fresh row.
    static func packRows(in configs: [ControlTileConfig]) -> [[ControlTileConfig]] {
        var rows: [[ControlTileConfig]] = []
        var row: [ControlTileConfig] = []
        var used = 0
        for config in configs where config.visible {
            let span = min(config.size.columnSpan, columns)
            if used + span > columns {
                if !row.isEmpty { rows.append(row) }
                row = []
                used = 0
            }
            row.append(config)
            used += span
            if used >= columns {
                rows.append(row)
                row = []
                used = 0
            }
        }
        if !row.isEmpty { rows.append(row) }
        return rows
    }

    // Hex colours <-> ControlTileConfig.tintHex

    static func hex(from color: Color) -> String? {
        guard let rgb = color.resolvedRGB() else { return nil }
        return String(format: "%02X%02X%02X",
                      Int((rgb.r * 255).rounded()),
                      Int((rgb.g * 255).rounded()),
                      Int((rgb.b * 255).rounded()))
    }

    static func color(hex: String?) -> Color? {
        guard let hex, hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}

private extension Color {
    /// Best-effort sRGB components for hex persistence; nil for dynamic
    /// colors that cannot be flattened outside a render context.
    func resolvedRGB() -> (r: Double, g: Double, b: Double)? {
        #if canImport(UIKit)
        return nil
        #else
        let ns = NSColor(self).usingColorSpace(.sRGB)
        guard let ns else { return nil }
        return (Double(ns.redComponent), Double(ns.greenComponent), Double(ns.blueComponent))
        #endif
    }
}
