//
//  WordSuggestions.swift
//  GeneralKeyboard
//
//  Created by Enver Eskendarov on 6/28/26.
//
//  Reader for the bundled, read-only dictionary artifact (`<wordsArtifact>.sqlite`).
//  Schema, metadata and the base_score contract: docs/ARTIFACT_CONTRACT.md.
//

import Foundation
import SQLite3

/// Prefix lookup in the bundled dictionary.
///
/// Words are stored in the canonical form (`Normalization`), so a lookup
/// normalizes its input and then compares bytes — no per-row work, and the
/// primary-key index can be used.
final class WordSuggestions {
    private var db: OpaquePointer?
    private var stmt: OpaquePointer?

    /// Artifact metadata, read once at open. Nil for a pre-metadata
    /// artifact (the released 1.2.0 dictionary had none).
    private(set) var metadata: ArtifactMetadata?

    /// Newest artifact schema this reader understands.
    static let supportedSchemaVersion = 1

    /// Resource name and expected `artifact` meta value, from the keyboard
    /// definition. Resolved in `Bundle.main` — the keyboard extension —
    /// whether the engine is linked statically or as a framework.
    static var artifactName: String { KeyboardDefinition.current.data.wordsArtifact }

    /// Whether the artifact carries a `base_score` column. False for the
    /// pre-metadata artifact, in which case ordering falls back to length
    /// alone — exactly the released behavior.
    private let hasBaseScore: Bool

    init?(databaseURL: URL? = nil) {
        let url = databaseURL ?? Bundle.main.url(forResource: Self.artifactName, withExtension: "sqlite")
        guard let url else { return nil }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }

        metadata = ArtifactMetadata.read(from: db, expecting: Self.artifactName)
        // An artifact from the future is treated as absent: reading the
        // dictionary wrongly is worse than having no dictionary.
        if let metadata, metadata.minReaderSchema > Self.supportedSchemaVersion {
            sqlite3_close(db)
            return nil
        }

        hasBaseScore = Self.columnExists("base_score", table: "words", db: db)

        // Explicit range instead of LIKE: SQLite cannot use the index for
        // `word LIKE 'p%'` on a BINARY-collated column while
        // case_sensitive_like is off, so the released query scanned all
        // 20 354 rows on every keystroke. The range is byte-identical for
        // this data — LIKE is case-insensitive for ASCII only, and this
        // dictionary is Cyrillic.
        let ordering = hasBaseScore ? "base_score DESC, LENGTH(word)" : "LENGTH(word)"
        let sql = """
            SELECT word FROM words
            WHERE word >= ?1 AND word < ?2
            ORDER BY \(ordering) LIMIT 3
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    }

    /// Upper bound of a prefix range: the prefix with the highest scalar
    /// appended, so every string starting with the prefix sorts below it.
    private static func upperBound(_ prefix: String) -> String {
        prefix + "\u{10FFFF}"
    }

    private static func columnExists(_ column: String, table: String, db: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK
        else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1), String(cString: c) == column { return true }
        }
        return false
    }

    func suggestions(for prefix: String) -> [String] {
        let normalized = Normalization.canonical(prefix)
        guard !normalized.isEmpty, let stmt else { return [] }
        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (Self.upperBound(normalized) as NSString).utf8String, -1, nil)
        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { results.append(String(cString: c)) }
        }
        return results
    }

    /// Exact-word membership, in the canonical form.
    func contains(_ word: String) -> Bool {
        let normalized = Normalization.canonical(word)
        guard !normalized.isEmpty else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM words WHERE word = ?1 LIMIT 1",
                                 -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (normalized as NSString).utf8String, -1, nil)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// Random dictionary words for the idle suggestion bar. Queried on the
    /// transition into idle, so the scan over the small dictionary is
    /// imperceptible.
    func randomWords(_ count: Int) -> [String] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT word FROM words ORDER BY RANDOM() LIMIT ?1",
                                 -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(count))
        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { results.append(String(cString: c)) }
        }
        return results
    }

    deinit { sqlite3_finalize(stmt); sqlite3_close(db) }
}

/// Version and provenance of a bundled artifact. See
/// docs/ARTIFACT_CONTRACT.md §1.
struct ArtifactMetadata {
    let artifact: String
    let schemaVersion: Int
    let contentVersion: Int
    let normalizationVersion: Int
    let minReaderSchema: Int
    let rowCount: Int

    /// Reads the `meta` table. Returns nil when the table is absent (a
    /// pre-metadata artifact) or the `artifact` key does not match, which
    /// also catches loading the wrong file.
    static func read(from db: OpaquePointer?, expecting kind: String) -> ArtifactMetadata? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT key, value FROM meta", -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }

        var values: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let k = sqlite3_column_text(stmt, 0), let v = sqlite3_column_text(stmt, 1) {
                values[String(cString: k)] = String(cString: v)
            }
        }
        guard values["artifact"] == kind else { return nil }
        return ArtifactMetadata(
            artifact: kind,
            schemaVersion: Int(values["schema_version"] ?? "") ?? 0,
            contentVersion: Int(values["content_version"] ?? "") ?? 0,
            normalizationVersion: Int(values["normalization_version"] ?? "") ?? 0,
            minReaderSchema: Int(values["min_reader_schema"] ?? "") ?? 0,
            rowCount: Int(values["row_count"] ?? "") ?? 0
        )
    }
}
