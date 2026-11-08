/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import XCTest
@testable import Atoll

final class LiquidGlassVariantTests: XCTestCase {

    func testOpacityScaleRunsTransparentToOpaque() {
        // The glass sliders mean one thing now: left = transparent, right
        // = opaque. The endpoints must hit exactly 0 and 1.
        XCTAssertEqual(LiquidGlassVariant.v0.backgroundOpacity, 0, accuracy: 0.0001)
        XCTAssertEqual(LiquidGlassVariant.v19.backgroundOpacity, 1, accuracy: 0.0001)
    }

    func testOpacityScaleIsMonotonic() {
        // Every step right adds opacity; Apple's variant numbers promised
        // no such order, which is why the raw value can no longer drive the
        // private variant for slider-backed panels.
        var previous = -1.0
        for variant in LiquidGlassVariant.allCases.sorted(by: { $0.rawValue < $1.rawValue }) {
            let opacity = variant.backgroundOpacity
            XCTAssertGreaterThan(opacity, previous, "\(variant) regressed")
            previous = opacity
        }
    }

    func testDefaultVariantIsMidScale() {
        XCTAssertEqual(LiquidGlassVariant.defaultVariant, .v11)
        XCTAssertEqual(LiquidGlassVariant.v11.backgroundOpacity, 11.0 / 19.0, accuracy: 0.0001)
    }
}
