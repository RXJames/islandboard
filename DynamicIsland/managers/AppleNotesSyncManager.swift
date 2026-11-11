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

import Foundation
import Defaults

#if canImport(AppKit)
import AppKit
#endif

enum AppleNotesSyncError: LocalizedError {
    case automationDenied
    case scriptFailed(String)

    var errorDescription: String? {
        switch self {
        case .automationDenied:
            return String(localized: "Allow IslandBoard to control Notes in System Settings → Privacy & Security → Automation.")
        case .scriptFailed(let message):
            return message
        }
    }
}

struct RemoteAppleNote: Sendable {
    let id: String
    let title: String
    let content: String
    let creationDate: Date
    let modificationDate: Date
    let atollId: UUID?
    /// Password-protected notes cannot be read over AppleScript. They are
    /// reported as alive-but-unreadable so the merge never prunes their local
    /// rows (and never pushes over them), instead of looking deleted.
    var isLocked: Bool = false
}

@MainActor
final class AppleNotesSyncManager: ObservableObject {
    static let shared = AppleNotesSyncManager()

    @Published private(set) var isSyncing = false
    @Published private(set) var lastError: String?

    private static let syncFolderName = "IslandBoard"
    static let fieldSeparator = "\u{241F}"
    static let recordSeparator = "\u{241E}"
    private static let atollTagPattern = #"<!--atoll:id=([0-9A-Fa-f-]{36})-->"#

    private var syncTask: Task<Void, Never>?
    private var pendingSync = false
    private var refreshTask: Task<Void, Never>?
    private var notesQuitObserver: NSObjectProtocol?

    private init() {}

    func requestSync(localNotes: [NoteItem]) {
        guard Defaults[.enableAppleNotesSync] else { return }
        ensureWatching()
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            guard let self else { return }
            if let merged = await self.sync(localNotes: localNotes) {
                Defaults[.savedNotes] = merged
            }
        }
    }

    @discardableResult
    func sync(localNotes: [NoteItem]) async -> [NoteItem]? {
        guard Defaults[.enableAppleNotesSync] else { return nil }
        ensureWatching()
        // A refresh that races an in-flight sync must not be dropped: mark it
        // pending and rerun the cycle when the current one finishes.
        guard !isSyncing else {
            pendingSync = true
            return nil
        }

        isSyncing = true
        lastError = nil
        defer { isSyncing = false }

        var snapshot = localNotes
        var result: [NoteItem]?
        repeat {
            pendingSync = false
            do {
                let remoteNotes = try await fetchRemoteNotes()
                var merged = try await merge(localNotes: snapshot, remoteNotes: remoteNotes)
                merged = try await pushUnlinkedLocalNotes(merged)
                Defaults[.appleNotesLastSyncDate] = Date()
                result = merged
                snapshot = merged
            } catch {
                lastError = error.localizedDescription
                result = nil
            }
        } while pendingSync
        return result
    }

    /// Background liveness for the AppleScript-backed sync: Notes.app offers
    /// no store-change notification, so deletions made there surface on a 60 s
    /// loop and immediately when Notes quits (edits flushed to disk).
    private func ensureWatching() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, Defaults[.enableAppleNotesSync] else { continue }
                await self.requestSyncQuietly()
            }
        }
        notesQuitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.Notes" else { return }
            Task { @MainActor in await self?.requestSyncQuietly() }
        }
    }

    private func requestSyncQuietly() async {
        if let merged = await sync(localNotes: Defaults[.savedNotes]) {
            Defaults[.savedNotes] = merged
        }
    }

    func pushNote(_ note: NoteItem) async -> NoteItem? {
        guard Defaults[.enableAppleNotesSync] else { return nil }

        do {
            if let appleNotesId = note.appleNotesId {
                try await updateRemoteNote(id: appleNotesId, note: note)
                return note
            } else {
                let newId = try await createRemoteNote(note)
                var updated = note
                updated.appleNotesId = newId
                return updated
            }
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func deleteRemoteNote(appleNotesId: String) async {
        guard Defaults[.enableAppleNotesSync] else { return }

        do {
            try await deleteRemoteNote(id: appleNotesId)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Merge

    private func merge(localNotes: [NoteItem], remoteNotes: [RemoteAppleNote]) async throws -> [NoteItem] {
        var notes = localNotes
        // Apple Notes 可能回吐同 id 的重复条目（跨账户/重复抓取），uniqueKeysWithValues 遇重复会 fatalError。
        // 改用 uniquingKeysWith，冲突时保留修改时间更新的一条。
        var remoteById = Dictionary(
            remoteNotes.map { ($0.id, $0) },
            uniquingKeysWith: { lhs, rhs in rhs.modificationDate > lhs.modificationDate ? rhs : lhs }
        )
        var linkedRemoteIds = Set<String>()

        for index in notes.indices {
            guard let appleNotesId = notes[index].appleNotesId,
                  let remote = remoteById[appleNotesId] else { continue }

            linkedRemoteIds.insert(appleNotesId)
            // Locked remote notes cannot be read or written safely: keep the
            // local copy untouched.
            if remote.isLocked { continue }

            if remote.modificationDate > notes[index].modificationDate {
                applyRemote(remote, to: &notes[index])
            } else if notes[index].modificationDate > remote.modificationDate {
                try await updateRemoteNote(id: appleNotesId, note: notes[index])
            }
        }

        // 遍历去重后的 remoteById.values 而非原始 remoteNotes：否则同 id 的旧副本可能先被
        // 处理并占位，新副本被跳过，atollId 匹配与新笔记导入的结果就会依赖数组顺序。
        for remote in remoteById.values where !linkedRemoteIds.contains(remote.id) {
            if remote.isLocked { continue } // unreadable; importing an empty shell would be worse
            if let atollId = remote.atollId,
               let index = notes.firstIndex(where: { $0.id == atollId }) {
                linkedRemoteIds.insert(remote.id)
                notes[index].appleNotesId = remote.id
                if remote.modificationDate > notes[index].modificationDate {
                    applyRemote(remote, to: &notes[index])
                }
                continue
            }

            let imported = NoteItem(
                title: sanitizedTitle(remote.title),
                content: remote.content,
                creationDate: remote.creationDate,
                modificationDate: remote.modificationDate,
                colorIndex: 0,
                appleNotesId: remote.id
            )
            notes.append(imported)
            linkedRemoteIds.insert(remote.id)
        }

        notes.removeAll { note in
            guard let appleNotesId = note.appleNotesId else { return false }
            return !linkedRemoteIds.contains(appleNotesId) && remoteById[appleNotesId] == nil
        }

        return notes.sorted { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned && !rhs.isPinned }
            return lhs.modificationDate > rhs.modificationDate
        }
    }

    private func pushUnlinkedLocalNotes(_ notes: [NoteItem]) async throws -> [NoteItem] {
        var updated = notes
        for index in updated.indices where updated[index].appleNotesId == nil {
            let newId = try await createRemoteNote(updated[index])
            updated[index].appleNotesId = newId
        }
        return updated
    }

    private func applyRemote(_ remote: RemoteAppleNote, to note: inout NoteItem) {
        note.title = sanitizedTitle(remote.title)
        note.content = remote.content
        note.creationDate = remote.creationDate
        note.modificationDate = remote.modificationDate
        note.appleNotesId = remote.id
    }

    private func sanitizedTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Untitled Note") : trimmed
    }

    /// Drops the leading line of `content` when it repeats `title` — the shape
    /// AppleScript's `plaintext` always has, because Notes renders the title as
    /// the first body line. Self-heals notes synced while the title/body split
    /// was broken.
    static func stripLeadingTitle(_ content: String, title: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty, !trimmedTitle.isEmpty else { return content }
        guard let newline = content.firstIndex(of: "\n") else {
            return content.trimmingCharacters(in: .whitespacesAndNewlines) == trimmedTitle ? "" : content
        }
        let firstLine = String(content[..<newline]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard firstLine == trimmedTitle else { return content }
        return String(content[content.index(after: newline)...])
    }

    // MARK: - AppleScript bridge

    private func fetchRemoteNotes() async throws -> [RemoteAppleNote] {
        // Notes.app has no "deleted" AppleScript flag: soft-deleted notes keep
        // being enumerated from the "Recently Deleted" folder, which is only
        // identifiable by its (localized) name. Enumerating them as live is what
        // used to keep deleted notes alive in IslandBoard forever, so the folder is
        // skipped by the per-locale name list Apple ships.
        let trashNames = [
            "Recently Deleted", "最近删除", "最近刪除", "Supprimés récemment",
            "Zuletzt gelöscht", "Eliminati di recente", "Eliminados recientemente",
            "Apagados recentemente", "削除した項目", "최근 삭제된 항목",
            "Недавно удаленные", "العناصر المحذوفة مؤخرًا", "Recent verwijderd",
            "Ostatnio usunięte", "Son Silinenler", "Baru Dihapus", "Nyligen raderade",
        ]
        let trashLiteral = trashNames.map { "\"\($0)\"" }.joined(separator: ", ")
        let script = """
        set fieldSep to "\(Self.fieldSeparator)"
        set recordSep to "\(Self.recordSeparator)"
        set trashNames to {\(trashLiteral)}
        tell application "Notes"
            set epoch to (current date)
            set hours of epoch to 0
            set minutes of epoch to 0
            set seconds of epoch to 0
            set year of epoch to 1970
            set month of epoch to January
            set day of epoch to 1
            set chunks to {}
            repeat with f in folders of default account
                if (name of f) is in trashNames then
                    -- skip soft-deleted notes entirely
                else
                    repeat with n in notes of f
                        if password protected of n then
                            -- Alive but unreadable: id-only marker, locked flag set.
                            set end of chunks to (id of n) & fieldSep & fieldSep & fieldSep & fieldSep & fieldSep & fieldSep & "1"
                        else
                            set notePlain to plaintext of n
                            set notePlain to my sanitizeField(notePlain, fieldSep, recordSep)
                            set atollId to my extractAtollId(body of n)
                            set chunk to (id of n) & fieldSep & (name of n) & fieldSep & ((creation date of n) - epoch as string) & fieldSep & ((modification date of n) - epoch as string) & fieldSep & notePlain & fieldSep & atollId & fieldSep & "0"
                            set end of chunks to chunk
                        end if
                    end repeat
                end if
            end repeat
            set AppleScript's text item delimiters to recordSep
            return chunks as text
        end tell

        on sanitizeField(txt, fieldSep, recordSep)
            set AppleScript's text item delimiters to fieldSep
            set parts to text items of txt
            set AppleScript's text item delimiters to " "
            set txt to parts as text
            set AppleScript's text item delimiters to recordSep
            set parts to text items of txt
            set AppleScript's text item delimiters to " "
            return parts as text
        end sanitizeField

        on extractAtollId(noteBody)
            if noteBody does not contain "atoll:id=" then return ""
            set AppleScript's text item delimiters to "atoll:id="
            set tail to item 2 of (text items of noteBody)
            set AppleScript's text item delimiters to "-->"
            return item 1 of (text items of tail)
        end extractAtollId
        """

        let output = try await runScriptReturningString(script)
        return parseRemoteNotes(output)
    }

    func parseRemoteNotes(_ payload: String) -> [RemoteAppleNote] {
        guard !payload.isEmpty else { return [] }

        return payload
            .split(separator: Character(Self.recordSeparator), omittingEmptySubsequences: true)
            .compactMap { record in
                let fields = record.split(separator: Character(Self.fieldSeparator), maxSplits: 6, omittingEmptySubsequences: false)
                guard fields.count >= 5 else { return nil }

                let id = String(fields[0])
                guard !id.isEmpty else { return nil }
                let locked = fields.count > 6 && String(fields[6]) == "1"
                if locked {
                    return RemoteAppleNote(
                        id: id, title: "", content: "",
                        creationDate: .distantPast, modificationDate: .distantPast,
                        atollId: nil, isLocked: true
                    )
                }

                let title = String(fields[1])
                guard let created = parseAppleScriptSeconds(String(fields[2])),
                      let modified = parseAppleScriptSeconds(String(fields[3])) else { return nil }

                // Notes derives the display name from the first body line, so
                // `plaintext` starts with the title. Store the remainder as the
                // content; keeping the title line in `content` too is what made
                // an edited body clobber the title and vice versa.
                let content = Self.stripLeadingTitle(String(fields[4]), title: title)
                let atollId = fields.count > 5
                    ? UUID(uuidString: String(fields[5]))
                    : extractAtollId(from: content)

                return RemoteAppleNote(
                    id: id,
                    title: title,
                    content: content,
                    creationDate: created,
                    modificationDate: modified,
                    atollId: atollId
                )
            }
    }

    private func parseAppleScriptSeconds(_ raw: String) -> Date? {
        let normalized = raw
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "E+", with: "e")
        guard let seconds = Double(normalized) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private func extractAtollId(from content: String) -> UUID? {
        guard let regex = try? NSRegularExpression(pattern: Self.atollTagPattern) else { return nil }
        let range = NSRange(content.startIndex..<content.endIndex, in: content)
        guard let match = regex.firstMatch(in: content, range: range),
              let idRange = Range(match.range(at: 1), in: content) else { return nil }
        return UUID(uuidString: String(content[idRange]))
    }

    private func createRemoteNote(_ note: NoteItem) async throws -> String {
        try await ensureSyncFolderExists()

        let title = appleScriptEscape(sanitizedTitle(note.title))
        let body = appleScriptEscape(htmlBody(for: note))

        let script = """
        tell application "Notes"
            set newNote to make new note at folder "\(Self.syncFolderName)" of default account with properties {name:"\(title)", body:"\(body)"}
            return id of newNote
        end tell
        """

        return try await runScriptReturningString(script)
    }

    private func updateRemoteNote(id: String, note: NoteItem) async throws {
        let title = appleScriptEscape(sanitizedTitle(note.title))
        let body = appleScriptEscape(htmlBody(for: note))
        let escapedId = appleScriptEscape(id)

        let script = """
        tell application "Notes"
            set targetNote to first note whose id is "\(escapedId)"
            set name of targetNote to "\(title)"
            set body of targetNote to "\(body)"
        end tell
        """

        try await runScriptVoid(script)
    }

    private func deleteRemoteNote(id: String) async throws {
        let escapedId = appleScriptEscape(id)
        let script = """
        tell application "Notes"
            set matches to every note whose id is "\(escapedId)"
            if (count of matches) > 0 then
                delete item 1 of matches
            end if
        end tell
        """
        try await runScriptVoid(script)
    }

    private func ensureSyncFolderExists() async throws {
        let script = """
        tell application "Notes"
            try
                set _folder to folder "\(Self.syncFolderName)" of default account
            on error
                make new folder at default account with properties {name:"\(Self.syncFolderName)"}
            end try
        end tell
        """
        try await runScriptVoid(script)
    }

    /// Canonical plain text pushed to Notes: title as the first line (Notes
    /// derives the visible name from it), then the content without its
    /// duplicated title line.
    static func plainBody(title: String, content: String) -> String {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = stripLeadingTitle(content, title: trimmedTitle)
        if trimmedTitle.isEmpty { return body }
        return body.isEmpty ? trimmedTitle : trimmedTitle + "\n" + body
    }

    static func htmlBody(plain: String, noteID: UUID) -> String {
        let escaped = plain
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")

        let html = escaped
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                if line.isEmpty { return "<div><br></div>" }
                return "<div>\(line)</div>"
            }
            .joined()

        return html + "<!--atoll:id=\(noteID.uuidString)-->"
    }

    private func htmlBody(for note: NoteItem) -> String {
        Self.htmlBody(
            plain: Self.plainBody(title: sanitizedTitle(note.title), content: note.content),
            noteID: note.id
        )
    }

    private func appleScriptEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r\n", with: "\\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\n")
    }

    private func runScriptReturningString(_ script: String) async throws -> String {
        let descriptor = try await executeScript(script)
        guard let value = descriptor.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw AppleNotesSyncError.scriptFailed(String(localized: "Notes returned an empty response."))
        }
        return value
    }

    private func runScriptVoid(_ script: String) async throws {
        _ = try await executeScript(script)
    }

    private func executeScript(_ script: String) async throws -> NSAppleEventDescriptor {
        do {
            guard let descriptor = try await AppleScriptHelper.execute(script) else {
                throw AppleNotesSyncError.scriptFailed(String(localized: "Notes script returned no result."))
            }
            return descriptor
        } catch let error as NSError {
            if error.domain == "AppleScriptError", (error.userInfo["NSAppleScriptErrorNumber"] as? Int) == -1743 {
                throw AppleNotesSyncError.automationDenied
            }
            let message = (error.userInfo["NSAppleScriptErrorMessage"] as? String) ?? error.localizedDescription
            throw AppleNotesSyncError.scriptFailed(message)
        }
    }
}
