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

import AppKit
import ImageIO
import SwiftUI

/// A pet in the Codex / petdex spritesheet format, installed by the petdex
/// CLI under `~/.codex/pets/<slug>/`.
///
/// The directory holds a `pet.json` (`displayName` / `description` /
/// `spritesheetPath`) and a sprite atlas whose frames are 192×208 px. The
/// current Codex atlas is 8 columns × 9 rows (1536×1872); older sheets are
/// 9 × 8 (1728×1664). Row order is the Codex state taxonomy, with `idle`
/// first; the first six columns of a row are the frames of that state.
final class CodexPet: Identifiable {
    static let frameWidth = 192
    static let frameHeight = 208
    static let framesPerState = 6
    /// petdex's default full-loop duration for one state.
    static let loopDuration: TimeInterval = 1.1

    /// Codex row order (top to bottom) for the 9-row atlas.
    static let codexRows = [
        "idle", "running-right", "running-left", "waving", "jumping",
        "failed", "waiting", "running", "review"
    ]
    /// Legacy 8-row atlas order.
    static let legacyRows = [
        "idle", "wave", "run", "failed", "review", "jump", "extra1", "extra2"
    ]

    let directory: URL
    let id: String
    let displayName: String
    let summary: String
    let sheetURL: URL
    let columns: Int
    let rows: Int
    let framesPerState: Int
    let rowNames: [String]

    private let sheet: CGImage
    private var frameCache: [Int: CGImage] = [:]

    var idleRow: Int { rowNames.firstIndex(of: "idle") ?? 0 }

    /// Seconds a single frame stays on screen at `speed` 1.
    var frameInterval: TimeInterval { Self.loopDuration / Double(max(1, framesPerState)) }

    private init(directory: URL, id: String, displayName: String, summary: String,
                 sheetURL: URL, sheet: CGImage) {
        self.directory = directory
        self.id = id
        self.displayName = displayName
        self.summary = summary
        self.sheetURL = sheetURL
        self.sheet = sheet
        let derivedColumns = max(1, sheet.width / Self.frameWidth)
        let derivedRows = max(1, sheet.height / Self.frameHeight)
        columns = derivedColumns
        rows = derivedRows
        framesPerState = min(Self.framesPerState, derivedColumns)
        rowNames = derivedRows >= 9
            ? Self.codexRows
            : (derivedRows >= 8 ? Self.legacyRows : Array(Self.codexRows.prefix(derivedRows)))
    }

    // MARK: - Loading

    /// Reads `<directory>/pet.json` and its sprite atlas, or nil when the
    /// folder is not a usable pet.
    static func load(directory: URL) -> CodexPet? {
        let manifestURL = directory.appendingPathComponent("pet.json")
        let manifest: [String: Any]
        if let data = try? Data(contentsOf: manifestURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            manifest = object
        } else {
            manifest = [:]
        }

        guard let sheetURL = resolveSpritesheet(in: directory, manifest: manifest),
              let source = CGImageSourceCreateWithURL(sheetURL as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }

        let slug = directory.lastPathComponent
        let displayName = (manifest["displayName"] as? String)
            ?? (manifest["name"] as? String)
            ?? slug
        let id = (manifest["id"] as? String) ?? slug
        let summary = (manifest["description"] as? String) ?? ""

        return CodexPet(directory: directory, id: id, displayName: displayName,
                        summary: summary, sheetURL: sheetURL, sheet: sheet)
    }

    private static func resolveSpritesheet(in directory: URL,
                                           manifest: [String: Any]) -> URL? {
        var names: [String] = []
        if let declared = manifest["spritesheetPath"] as? String, !declared.isEmpty {
            names.append(declared)
        }
        names += ["spritesheet.webp", "spritesheet.png", "sprite.webp", "sprite.png"]
        return names
            .map { directory.appendingPathComponent($0) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: - Frames

    /// One cropped frame of the atlas. Frames are cached per pet because the
    /// animation view asks for the next one ~6×/second.
    func frame(row: Int, index: Int) -> CGImage? {
        guard row >= 0, row < rows, columns > 0 else { return nil }
        let column = ((index % framesPerState) + framesPerState) % framesPerState
        let key = row * 4096 + column
        if let cached = frameCache[key] { return cached }
        let rect = CGRect(x: column * Self.frameWidth,
                          y: row * Self.frameHeight,
                          width: Self.frameWidth,
                          height: Self.frameHeight)
        guard let cropped = sheet.cropping(to: rect) else { return nil }
        frameCache[key] = cropped
        return cropped
    }

    /// Every folder under `~/.codex/pets` that holds a readable pet.
    static func discover(in root: URL = defaultRoot) -> [CodexPet] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { load(directory: $0) }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/pets", isDirectory: true)
    }
}

// MARK: - Importing

enum CodexPetImportError: LocalizedError {
    case notAPet

    var errorDescription: String? {
        "That folder is not a Codex pet. Pick a folder that contains pet.json and its spritesheet (or a folder holding several such pet folders)."
    }
}

enum CodexPetImport {
    /// The pet(s) inside `folder`: the folder itself, or — when it is a
    /// container — its immediate child folders.
    static func pets(in folder: URL) -> [CodexPet] {
        if let pet = CodexPet.load(directory: folder) { return [pet] }
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return children
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .compactMap { CodexPet.load(directory: $0) }
    }

    /// Copies external pet folders into `~/.codex/pets` (where Codex/petdex
    /// keeps them) and returns the usable pets. Folders already inside the
    /// root are returned as-is.
    @discardableResult
    static func importPets(from folder: URL, into root: URL = CodexPet.defaultRoot) throws -> [CodexPet] {
        let found = pets(in: folder)
        guard !found.isEmpty else { throw CodexPetImportError.notAPet }

        let scoped = folder.startAccessingSecurityScopedResource()
        defer { if scoped { folder.stopAccessingSecurityScopedResource() } }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var imported: [CodexPet] = []

        for pet in found {
            let source = pet.directory.standardizedFileURL
            let rootPath = root.standardizedFileURL.path
            if source.path == rootPath || source.path.hasPrefix(rootPath + "/") {
                imported.append(pet)
                continue
            }

            let slug = sanitized(pet.id.isEmpty ? pet.directory.lastPathComponent : pet.id)
            var destination = root.appendingPathComponent(slug, isDirectory: true)
            var suffix = 2
            var reused: CodexPet?
            while FileManager.default.fileExists(atPath: destination.path) {
                if let existing = CodexPet.load(directory: destination), existing.id == pet.id {
                    reused = existing
                    break
                }
                destination = root.appendingPathComponent("\(slug)-\(suffix)", isDirectory: true)
                suffix += 1
            }
            if let reused {
                imported.append(reused)
                continue
            }
            do {
                try FileManager.default.copyItem(at: pet.directory, to: destination)
                imported.append(CodexPet.load(directory: destination) ?? pet)
            } catch {
                // One bad pet must not block the rest of a container import.
                continue
            }
        }

        guard !imported.isEmpty else { throw CodexPetImportError.notAPet }
        return imported
    }

    private static func sanitized(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let cleaned = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let slug = String(cleaned).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return slug.isEmpty ? "pet" : slug
    }
}

/// Main-actor cache so SwiftUI bodies can ask for a pet cheaply.
@MainActor
final class CodexPetStore {
    static let shared = CodexPetStore()

    private var cache: [String: CodexPet] = [:]

    func pet(at directory: URL) -> CodexPet? {
        let key = directory.standardizedFileURL.path
        if let cached = cache[key] { return cached }
        guard let pet = CodexPet.load(directory: directory) else { return nil }
        cache[key] = pet
        return pet
    }

    func invalidate() { cache.removeAll() }
}

/// Plays one state row of a Codex pet atlas (`idle`, `running-left/right`,
/// `waving`, `jumping`, …). Legacy 8-row sheets use the shorter names
/// (`run`, `wave`, `jump`), so those are accepted as aliases.
struct CodexPetView: View {
    let pet: CodexPet
    var state: String = "idle"
    var speed: CGFloat = 1.0

    private var row: Int {
        if let index = pet.rowNames.firstIndex(of: state) { return index }
        let aliases: [String: String] = [
            "running-right": "run", "running-left": "run",
            "waving": "wave", "jumping": "jump"
        ]
        if let alias = aliases[state], let index = pet.rowNames.firstIndex(of: alias) {
            return index
        }
        return pet.idleRow
    }

    var body: some View {
        let interval = max(0.05, pet.frameInterval / Double(max(0.1, speed)))
        TimelineView(.periodic(from: .now, by: interval)) { context in
            let tick = Int(context.date.timeIntervalSinceReferenceDate / interval)
            if let frame = pet.frame(row: row, index: tick) {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
        }
    }
}
