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

final class TabCatalogTests: XCTestCase {

    private func tab(_ view: NotchViews, _ label: String) -> TabModel {
        TabModel(label: label, icon: "circle", view: view)
    }

    private func ids(_ tabs: [TabModel]) -> [String] {
        tabs.map(\.id)
    }

    // MARK: ordered(by:)

    func testEmptyOrderKeepsCanonicalSequence() {
        let tabs = [tab(.home, "Home"), tab(.stats, "Stats"), tab(.terminal, "Terminal")]
        XCTAssertEqual(ids(TabCatalog.ordered(tabs, by: [])), ids(tabs))
    }

    func testSavedOrderPermutesKnownTabs() {
        let tabs = [tab(.home, "Home"), tab(.stats, "Stats"), tab(.terminal, "Terminal")]
        let order = [tabs[2].id, tabs[0].id, tabs[1].id]
        XCTAssertEqual(
            ids(TabCatalog.ordered(tabs, by: order)),
            [tabs[2].id, tabs[0].id, tabs[1].id]
        )
    }

    func testUnknownTabsAppendAfterKnownOnes() {
        // An upgrade adds a tab that predates the saved permutation: it must
        // show up, at the end, not vanish because the order list is stale.
        let tabs = [tab(.home, "Home"), tab(.stats, "Stats"), tab(.llmUsage, "Usage")]
        let order = [tabs[1].id, tabs[0].id]
        XCTAssertEqual(
            ids(TabCatalog.ordered(tabs, by: order)),
            [tabs[1].id, tabs[0].id, tabs[2].id]
        )
    }

    func testOrderEntryForMissingTabIsIgnored() {
        // A disabled feature's stale id must not break ordering.
        let tabs = [tab(.home, "Home"), tab(.stats, "Stats")]
        let ghost = "system-llmUsage-Usage"
        let order = [ghost, tabs[1].id, tabs[0].id]
        XCTAssertEqual(
            ids(TabCatalog.ordered(tabs, by: order)),
            [tabs[1].id, tabs[0].id]
        )
    }

    // MARK: moved(dragging:to:)

    func testMovedLeftwardPlacesGapAtTarget() {
        let ids = ["a", "b", "c", "d"]
        XCTAssertEqual(TabCatalog.moved(ids, dragging: "d", to: 1), ["a", "d", "b", "c"])
    }

    func testMovedRightwardPlacesGapAtTarget() {
        let ids = ["a", "b", "c", "d"]
        XCTAssertEqual(TabCatalog.moved(ids, dragging: "a", to: 2), ["b", "c", "a", "d"])
    }

    func testMovedToOwnIndexIsNoop() {
        let ids = ["a", "b", "c"]
        XCTAssertEqual(TabCatalog.moved(ids, dragging: "b", to: 1), ids)
    }

    func testMovedClampsToRange() {
        let ids = ["a", "b"]
        XCTAssertEqual(TabCatalog.moved(ids, dragging: "a", to: 9), ["b", "a"])
        XCTAssertEqual(TabCatalog.moved(ids, dragging: "b", to: -3), ["b", "a"])
    }

    func testMovedWithUnknownIDIsNoop() {
        let ids = ["a", "b"]
        XCTAssertEqual(TabCatalog.moved(ids, dragging: "x", to: 0), ids)
    }

    func testConsecutiveGapMovesRemainPermutations() {
        // Every pointer-cross during one drag re-inserts the gap; the
        // preview order must stay a permutation of the same ids.
        var ids = ["a", "b", "c", "d"]
        ids = TabCatalog.moved(ids, dragging: "a", to: 3)
        ids = TabCatalog.moved(ids, dragging: "d", to: 1)
        ids = TabCatalog.moved(ids, dragging: "c", to: 0)
        XCTAssertEqual(ids.count, 4)
        XCTAssertEqual(Set(ids), Set(["a", "b", "c", "d"]))
    }
}
#endif
