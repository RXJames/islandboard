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

    // MARK: Title/body split (title is the first body line in Notes.app)

    private func record(id: String, title: String, plaintext: String) -> String {
        "\(id)\(fieldSep)\(title)\(fieldSep)100\(fieldSep)200\(fieldSep)\(plaintext)\(fieldSep)\(fieldSep)0"
    }

    func testParseDropsTitleLineFromContent() {
        let payload = record(id: "n1", title: "Groceries", plaintext: "Groceries\nMilk\nEggs")
        let notes = AppleNotesSyncManager.shared.parseRemoteNotes(payload)
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(notes[0].title, "Groceries")
        XCTAssertEqual(notes[0].content, "Milk\nEggs")
    }

    func testParseTitleOnlyNoteYieldsEmptyContent() {
        let payload = record(id: "n2", title: "Just a title", plaintext: "Just a title")
        let notes = AppleNotesSyncManager.shared.parseRemoteNotes(payload)
        XCTAssertEqual(notes.first?.content, "")
    }

    func testParseKeepsContentWhenFirstLineIsNotTheTitle() {
        // Defensive: never eat a real content line just because it is first.
        let payload = record(id: "n3", title: "Groceries", plaintext: "Milk\nEggs")
        let notes = AppleNotesSyncManager.shared.parseRemoteNotes(payload)
        XCTAssertEqual(notes.first?.content, "Milk\nEggs")
    }

    func testPlainBodyPutsTitleFirstAndDedupesStoredTitle() {
        // Legacy stored content still carries the title line; pushing must not
        // duplicate it.
        XCTAssertEqual(
            AppleNotesSyncManager.plainBody(title: "Groceries", content: "Groceries\nMilk"),
            "Groceries\nMilk"
        )
        XCTAssertEqual(
            AppleNotesSyncManager.plainBody(title: "Groceries", content: "Milk"),
            "Groceries\nMilk"
        )
        XCTAssertEqual(AppleNotesSyncManager.plainBody(title: "Only title", content: ""), "Only title")
    }

    func testRoundTripPushThenFetchIsStable() {
        // Push renders title+content; Notes' plaintext for that body is exactly
        // `plainBody`; fetching it back must yield the same title/content pair.
        let title = "Meeting"
        let content = "agenda A\nagenda B"
        let plain = AppleNotesSyncManager.plainBody(title: title, content: content)
        XCTAssertEqual(plain, "Meeting\nagenda A\nagenda B")
        let payload = record(id: "n4", title: title, plaintext: plain)
        let notes = AppleNotesSyncManager.shared.parseRemoteNotes(payload)
        XCTAssertEqual(notes.first?.title, title)
        XCTAssertEqual(notes.first?.content, content)
    }

    func testHtmlBodyEscapesAndTagsEachLine() {
        let id = UUID(uuidString: "6E2F3A4B-5C6D-7E8F-9A0B-1C2D3E4F5A6B")!
        let html = AppleNotesSyncManager.htmlBody(plain: "A & B\n<safe>", noteID: id)
        XCTAssertTrue(html.hasPrefix("<div>A &amp; B</div>"))
        XCTAssertTrue(html.contains("<div>&lt;safe&gt;</div>"))
        XCTAssertTrue(html.hasSuffix("<!--atoll:id=\(id.uuidString)-->"))
    }
}
