//
//  IdlePetGeometryTests.swift
//  DynamicIslandTests
//
//  Copyright (C) Atoll Contributors
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import XCTest
import CoreGraphics
@testable import IslandBoard

final class IdlePetGeometryTests: XCTestCase {

    // MARK: faceSide

    func testFaceSideStaysWithinNotchHeight() {
        // 100% means flush: the pet touches the notch's edge but never
        // exceeds it.
        for height in [24.0, 32.0, 40.0, 60.0] {
            let side = IdlePetGeometry.faceSide(notchWidth: 200, notchHeight: height, scale: 1.0)
            XCTAssertLessThanOrEqual(side, height, "height \(height) overflowed the cap")
            XCTAssertGreaterThan(side, 0)
        }
    }

    func testFaceSideAtFullScaleIsFlush() {
        // A normal notch: the area term exceeds the height cap, so 100%
        // lands exactly on the notch height.
        XCTAssertEqual(IdlePetGeometry.faceSide(notchWidth: 200, notchHeight: 32, scale: 1.0), 32, accuracy: 0.0001)
    }

    func testFaceSideGrowsWithNotchArea() {
        // Same width, taller notch (bigger face area) => bigger pet.
        let small = IdlePetGeometry.faceSide(notchWidth: 200, notchHeight: 32, scale: 1.0)
        let large = IdlePetGeometry.faceSide(notchWidth: 200, notchHeight: 48, scale: 1.0)
        XCTAssertGreaterThan(large, small)
    }

    func testFaceSideHonoursUserScale() {
        let full = IdlePetGeometry.faceSide(notchWidth: 200, notchHeight: 32, scale: 1.0)
        let half = IdlePetGeometry.faceSide(notchWidth: 200, notchHeight: 32, scale: 0.5)
        XCTAssertEqual(half, full * 0.5, accuracy: 0.0001)
        // Slider clamps live in the UI; geometry still refuses negatives.
        XCTAssertGreaterThan(IdlePetGeometry.faceSide(notchWidth: 200, notchHeight: 32, scale: -1), 0)
    }

    func testFaceSideInvalidNotchIsZero() {
        XCTAssertEqual(IdlePetGeometry.faceSide(notchWidth: 0, notchHeight: 32, scale: 1), 0)
        XCTAssertEqual(IdlePetGeometry.faceSide(notchWidth: 200, notchHeight: -5, scale: 1), 0)
    }

    // MARK: loopDuration

    func testLoopDurationParsesLottieHeader() throws {
        let json = #"{"fr":30,"ip":0,"op":90,"v":"5.7.4"}"#.data(using: .utf8)!
        XCTAssertEqual(IdlePetGeometry.loopDuration(lottieData: json, speed: 1), 3, accuracy: 0.0001)
        XCTAssertEqual(IdlePetGeometry.loopDuration(lottieData: json, speed: 2), 1.5, accuracy: 0.0001)
        // Garbage or missing data must fall back, never trap.
        XCTAssertEqual(IdlePetGeometry.loopDuration(lottieData: nil, speed: 1), 3)
        XCTAssertEqual(IdlePetGeometry.loopDuration(lottieData: Data("garbage".utf8), speed: 1), 3)
    }

    // MARK: patrolSegment

    func testPatrolSegmentKeepsClearOfNotchOnTheRight() {
        // 1440-wide screen, notch centred (width 200), pet 26.
        let seg = IdlePetGeometry.patrolSegment(screenMinX: 0, screenMaxX: 1440,
                                                notchMinX: 620, notchMaxX: 820,
                                                petSize: 26)
        XCTAssertNotNil(seg)
        // Never enters the notch strip horizontally...
        XCTAssertGreaterThanOrEqual(seg!.lowerBound, 820)
        // ...and never runs off the right edge.
        XCTAssertLessThanOrEqual(seg!.upperBound + 26, 1440)
    }

    func testPatrolSegmentFallsBackToLeftWhenRightIsTooNarrow() {
        // Notch hugging the right edge leaves only the left side usable.
        let seg = IdlePetGeometry.patrolSegment(screenMinX: 0, screenMaxX: 900,
                                                notchMinX: 860, notchMaxX: 900,
                                                petSize: 30)
        XCTAssertNotNil(seg)
        XCTAssertLessThanOrEqual(seg!.upperBound + 30, 860)
    }

    func testPatrolSegmentNilWhenNoSideHasRoom() {
        // A notch that leaves neither side usable must NOT be crossed - the
        // pet stays put rather than walking over the camera cutout.
        let seg = IdlePetGeometry.patrolSegment(screenMinX: 0, screenMaxX: 220,
                                                notchMinX: 10, notchMaxX: 210,
                                                petSize: 30)
        XCTAssertNil(seg)
    }
}
