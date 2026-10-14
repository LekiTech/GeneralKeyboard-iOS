//
//  StaticBigrams.swift
//  GeneralKeyboard
//
//  Reader for the bundled, read-only dictionary artifact (`<bigramsArtifact>.sqlite`):
//  corpus-derived (previous word → next word) weights that give the
//  dictionary some sense of context.
//
//  How a keyboard derives its pairs is the product's business (Avar, for
//  example, builds them from its dictionary's example sentences). Everything
//  here is written so that an empty or missing file produces exactly the
//  released behavior — see docs/engine/ARTIFACT_CONTRACT.md §4 for the
//  precedence contract, and the ranking tests for the equivalence proof.
//

import Foundation
import SQLite3

final class StaticBigrams {
    private var db: OpaquePointer?

    private(set) var metadata: ArtifactMetadata?

    static let supportedSchemaVersion = 1

    /// Resource name and expected `artifact` meta value, from the keyboard
    /// definition. Resolved in `Bundle.main` — the keyboard extension —
    /// whether the engine is linked statically or as a framework.
    static var artifactName: String { KeyboardDefinition.current.data.bigramsArtifact }

    /// True when the artifact holds no pairs at all. The ranking code uses
    /// it to skip every static-context query outright, so an empty artifact
    /// costs nothing on the typing path.
    let isEmpty: Bool

    init?(databaseURL: URL? = nil) {
        let url = databaseURL ?? Bundle.main.url(forResource: Self.artifactName, withExtension: "sqlite")
        guard let url else { return nil }
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }

        metadata = ArtifactMetadata.read(from: db, expecting: Self.artifactName)
        if let metadata, metadata.minReaderSchema > Self.supportedSchemaVersion {
            sqlite3_close(db)
            return nil
        }

        // Trust the recorded row count when present, so the common empty
        // case does not even run a COUNT(*).
        if let rows = metadata?.rowCount {
            isEmpty = rows == 0
        } else {
            var stmt: OpaquePointer?
            var count = 0
            if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM bigrams", -1, &stmt, nil) == SQLITE_OK,
               sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int64(stmt, 0))
            }
            sqlite3_finalize(stmt)
            isEmpty = count == 0
        }
    }

    /// Static weights for the given candidates after `previous`, keyed by
    /// candidate. Missing candidates simply have no entry — the caller
    /// treats that as weight 0, which preserves their existing order.
    ///
    /// One indexed query per lookup, bounded by the candidate count (at
    /// most three on the typing path).
    func weights(after previous: String, candidates: [String]) -> [String: Int] {
        guard !isEmpty, !candidates.isEmpty else { return [:] }
        let prev = Normalization.canonical(previous)
        guard !prev.isEmpty else { return [:] }

        let placeholders = Array(repeating: "?", count: candidates.count).joined(separator: ",")
        let sql = """
            SELECT word, weight FROM bigrams
            WHERE prev = ?1 AND word IN (\(placeholders))
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (prev as NSString).utf8String, -1, nil)
        for (index, candidate) in candidates.enumerated() {
            let normalized = Normalization.canonical(candidate)
            sqlite3_bind_text(stmt, Int32(index + 2), (normalized as NSString).utf8String, -1, nil)
        }

        var result: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) {
                result[String(cString: c)] = Int(sqlite3_column_int64(stmt, 1))
            }
        }
        return result
    }

    /// Likely continuations of `previous`, heaviest first. Used only when
    /// personal bigrams have nothing to offer, so personal context always
    /// wins — see the precedence contract.
    func nextWords(after previous: String, limit: Int = 3) -> [String] {
        guard !isEmpty else { return [] }
        let prev = Normalization.canonical(previous)
        guard !prev.isEmpty else { return [] }

        var stmt: OpaquePointer?
        let sql = """
            SELECT word FROM bigrams
            WHERE prev = ?1
            ORDER BY weight DESC, word ASC
            LIMIT ?2
            """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (prev as NSString).utf8String, -1, nil)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var results: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { results.append(String(cString: c)) }
        }
        return results
    }

    deinit { sqlite3_close(db) }
}
