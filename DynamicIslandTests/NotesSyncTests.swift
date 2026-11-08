/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import XCTest
@testable import Atoll

@MainActor
final class NotesSyncTests: XCTestCase {

    private let fieldSep = "\u{241F}"
    private let recordSep = "\u{241E}"

    func testParseNormalRecordWithLockedFlag() {
        let payload = "x-coredata://p1\(fieldSep)Groceries\(fieldSep)1000000\(fieldSep)1000100\(fieldSep)buy milk\(fieldSep)6E2F3A4B-5C6D-7E8F-9A0B-1C2D3E4F5A6B\(fieldSep)0"
        let notes = AppleNotesSyncManager.shared.parseRemoteNotes(payload)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].id, "x-coredata://p1")
        XCTAssertEqual(notes[0].title, "Groceries")
        XCTAssertEqual(notes[0].content, "buy milk")
        XCTAssertEqual(notes[0].atollId, UUID(uuidString: "6E2F3A4B-5C6D-7E8F-9A0B-1C2D3E4F5A6B"))
        XCTAssertFalse(notes[0].isLocked)
    }

    func testParseLockedMarkerKeepsNoteAliveWithoutContent() {
        let payload = "x-coredata://locked1\(fieldSep)\(fieldSep)\(fieldSep)\(fieldSep)\(fieldSep)\(fieldSep)1"
        let notes = AppleNotesSyncManager.shared.parseRemoteNotes(payload)
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].isLocked)
        XCTAssertEqual(notes[0].id, "x-coredata://locked1")
    }

    func testParseMultipleRecordsAndGarbageTolerance() {
        let good = "idA\(fieldSep)A\(fieldSep)100\(fieldSep)200\(fieldSep)body A\(fieldSep)\(fieldSep)0"
        let locked = "idB\(fieldSep)\(fieldSep)\(fieldSep)\(fieldSep)\(fieldSep)\(fieldSep)1"
        let broken = "idC" + fieldSep // fewer than 5 fields
        let payload = [good, locked, broken].joined(separator: recordSep)
        let notes = AppleNotesSyncManager.shared.parseRemoteNotes(payload)
        XCTAssertEqual(notes.map(\.id), ["idA", "idB"])
    }

    func testContentContainingSeparatorsStillParsesViaMaxSplits() {
        // sanitizeField replaces separators with spaces before transport; parser
        // splits at most 6 times so multi-line content with odd characters stays intact.
        let content = "line one" + recordSep + "line two"
        let payload = "idX\(fieldSep)X\(fieldSep)100\(fieldSep)200\(fieldSep)\(content)\(fieldSep)\(fieldSep)0"
        let notes = AppleNotesSyncManager.shared.parseRemoteNotes(payload)
        XCTAssertEqual(notes.count, 1)
        XCTAssertFalse(notes[0].isLocked)
    }
}
