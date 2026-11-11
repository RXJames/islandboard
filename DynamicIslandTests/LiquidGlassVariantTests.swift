/*
 * IslandBoard (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import XCTest
@testable import IslandBoard

final class LiquidGlassVariantTests: XCTestCase {

    func testSolidityScaleRunsOpaqueToGlass() {
        // The glass sliders mean: left = fully opaque panel, right = pure
        // liquid glass. The overlay wash alpha must hit exactly 1 and 0.
        XCTAssertEqual(LiquidGlassVariant.v0.panelSolidity, 1, accuracy: 0.0001)
        XCTAssertEqual(LiquidGlassVariant.v19.panelSolidity, 0, accuracy: 0.0001)
    }

    func testSolidityScaleIsMonotonic() {
        // Every step right removes opacity; nothing hops between Apple's
        // undocumented look-up variants.
        var previous = 2.0
        for variant in LiquidGlassVariant.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            let solidity = variant.panelSolidity
            XCTAssertLessThan(solidity, previous, "\(variant) regressed")
            previous = solidity
        }
    }

    func testDefaultVariantIsMidScale() {
        XCTAssertEqual(LiquidGlassVariant.defaultVariant, .v11)
        XCTAssertEqual(LiquidGlassVariant.v11.panelSolidity, 8.0 / 19.0, accuracy: 0.0001)
    }
}
