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
import XCTest
@testable import IslandBoard

final class ControlCenterLayoutTests: XCTestCase {

    private func cfg(_ kind: ControlTileKind,
                     _ size: ControlTileSize = .small,
                     visible: Bool = true) -> ControlTileConfig {
        ControlTileConfig(kind: kind, size: size, visible: visible)
    }

    func testPackRowsWrapsOnOverflow() {
        // medium(2) + medium(2) fills a row; the next small starts a new one.
        let rows = ControlCenterLayout.packRows(in: [
            cfg(.wifi, .medium), cfg(.focus, .medium), cfg(.nightShift)
        ])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0].map(\.kind), [.wifi, .focus])
        XCTAssertEqual(rows[1].map(\.kind), [.nightShift])
    }

    func testPackRowsLargeTileOwnsRow() {
        let rows = ControlCenterLayout.packRows(in: [
            cfg(.wifi), cfg(.volume, .large), cfg(.nightShift)
        ])
        XCTAssertEqual(rows.map { $0.map(\.kind) }, [[.wifi], [.volume], [.nightShift]])
    }

    func testPackRowsSkipsHiddenTiles() {
        let rows = ControlCenterLayout.packRows(in: [
            cfg(.wifi), cfg(.nightShift, visible: false), cfg(.darkMode)
        ])
        XCTAssertEqual(rows.flatMap { $0 }.map(\.kind), [.wifi, .darkMode])
    }

    func testDefaultLayoutFitsThreeRows() {
        // Four small toggles, two full-width sliders, keyboard hidden: the
        // notch must not need a scroll on first launch.
        let rows = ControlCenterLayout.packRows(in: ControlTileKind.defaultLayout)
        XCTAssertEqual(rows.count, 3)
        XCTAssertFalse(ControlTileKind.defaultLayout.contains { $0.kind == .keyboard && $0.visible })
    }

    func testCycleSizeWrapsAround() {
        let configs = [cfg(.wifi, .large)]
        XCTAssertEqual(ControlCenterLayout.cycleSize(kind: .wifi, in: configs)[0].size, .small)
    }

    func testMovedReinsertsAtVisibleIndex() {
        let configs = [cfg(.wifi), cfg(.nightShift), cfg(.focus), cfg(.darkMode)]
        let moved = ControlCenterLayout.moved(configs, dragging: .darkMode, toVisibleIndex: 1)
        XCTAssertEqual(moved.map(\.kind), [.wifi, .darkMode, .nightShift, .focus])
    }

    func testMovedToEnd() {
        let configs = [cfg(.wifi), cfg(.focus), cfg(.darkMode)]
        let moved = ControlCenterLayout.moved(configs, dragging: .wifi, toVisibleIndex: 2)
        XCTAssertEqual(moved.map(\.kind), [.focus, .darkMode, .wifi])
    }

    func testMovedSkipsHiddenSlots() {
        // The hidden tile keeps its array slot; the dragged tile lands at
        // visible index 0, before the first visible tile.
        let configs = [cfg(.wifi), cfg(.keyboard, visible: false), cfg(.focus)]
        let moved = ControlCenterLayout.moved(configs, dragging: .focus, toVisibleIndex: 0)
        XCTAssertEqual(moved.map(\.kind), [.focus, .wifi, .keyboard])
        XCTAssertEqual(moved[2].visible, false)
    }

    func testMovedIgnoresUnknownKind() {
        let configs = [cfg(.wifi), cfg(.focus)]
        XCTAssertEqual(ControlCenterLayout.moved(configs, dragging: .nightShift, toVisibleIndex: 0).count, 2)
    }

    func testSetVisibleHidesOnly() {
        let configs = [cfg(.wifi), cfg(.focus)]
        let updated = ControlCenterLayout.setVisible(kind: .wifi, false, in: configs)
        XCTAssertEqual(updated[0].visible, false)
        XCTAssertEqual(updated[1].visible, true)
    }

    func testHexRoundTrip() {
        let hex = "0A84FF"
        let color = ControlCenterLayout.color(hex: hex)
        XCTAssertNotNil(color)
        XCTAssertEqual(ControlCenterLayout.hex(from: color!), hex)
        XCTAssertNil(ControlCenterLayout.color(hex: "zzz"))
        XCTAssertNil(ControlCenterLayout.color(hex: nil))
    }
}
#endif
