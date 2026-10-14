//
//  GoldenFixtureTests.swift
//
//  Runs the real migration entry point — LearnedWords(directory:) — against
//  a FROZEN copy of a schema-version-1 database built from the released
//  implementation (commit b0c06d6), not from the current test helpers. The
//  other migration tests construct their inputs with the same SQL helpers
//  the code under test uses; this one cannot, by construction, share a bug
//  with them. Provenance: scripts/make_golden_fixture_v1.py.
//

import XCTest
import CryptoKit
import SQLite3
@testable import GeneralKeyboard
@testable import GeneralKeyboardBridge
import GeneralKeyboardReference

final class GoldenFixtureTests: GKTestCase {

    /// SHA256 of the frozen fixture. If this fails, someone regenerated
    /// production-v1.sqlite — which is never a side effect of other work.
    /// A fixture change is a reviewed decision: add a NEW file instead.
    private static let frozenSHA256 =
        "c0c0c5c9a58b75a843392e2e2a6330b7f1ec202b469e46e2e5537cc622e40079"

    private var dir: URL!
    private var path: String { dir.appendingPathComponent("learned.sqlite").path }

    /// The word «йис» in NFD, byte-distinct from the precomposed form.
    private let nfdYis = "\u{0438}\u{0306}\u{0438}\u{0441}"

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("golden-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fixture = try XCTUnwrap(
            Bundle.module.url(forResource: "production-v1", withExtension: "sqlite",
                              subdirectory: "Fixtures"),
            "The fixture must ship with the test bundle")
        try FileManager.default.copyItem(at: fixture, to: URL(fileURLWithPath: path))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Raw access, independent of the code under test

    /// Read-write, not read-only: a WAL database with no sidecars cannot be
    /// read by a plain read-only connection, and this helper inspects the
    /// throwaway COPY — the frozen fixture itself is only ever read as raw
    /// bytes, by the SHA256 pin.
    private func raw<T>(_ body: (OpaquePointer?) -> T) -> T {
        var db: OpaquePointer?
        _ = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close(db) }
        return body(db)
    }

    private func rawRows(_ sql: String) -> [[String]] {
        raw { db in
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var rows: [[String]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rows.append((0..<sqlite3_column_count(stmt)).map { column in
                    sqlite3_column_text(stmt, column).map { String(cString: $0) } ?? "NULL"
                })
            }
            return rows
        }
    }

    /// The database's complete logical content, for idempotence comparison.
    /// Full rows everywhere — a count would hide a rerun that rewrote
    /// content while keeping cardinality.
    private func logicalDump() -> [[String]] {
        rawRows("SELECT 'w', word, count, picked, last_used FROM user_word ORDER BY word")
        + rawRows("SELECT 'b', prev, word, count, last_used FROM user_bigram ORDER BY prev, word")
        + rawRows("SELECT 'm', key, value FROM meta ORDER BY key")
        + rawRows("""
            SELECT 'o', kind, key, typed_delta, picked_delta, confirmations,
                   first_seen, updated_at, batch_id
            FROM outbox ORDER BY kind, key, batch_id
            """)
    }

    // MARK: - The fixture itself

    func testTheFixtureIsTheFrozenBytes() throws {
        let fixture = try XCTUnwrap(
            Bundle.module.url(forResource: "production-v1", withExtension: "sqlite",
                              subdirectory: "Fixtures"))
        let digest = SHA256.hash(data: try Data(contentsOf: fixture))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(digest, Self.frozenSHA256,
                       "production-v1.sqlite was regenerated. It must never be — "
                       + "add a new fixture file instead.")
    }

    func testTheFixtureIsGenuinelyVersionOneWithByteDistinctDefects() {
        XCTAssertEqual(rawRows("SELECT value FROM meta WHERE key='schema_version'"), [["1"]])
        XCTAssertEqual(rawRows("SELECT COUNT(*) FROM user_word"), [["10"]])
        XCTAssertEqual(rawRows("SELECT COUNT(*) FROM user_bigram"), [["5"]])
        XCTAssertEqual(rawRows("SELECT COUNT(*) FROM sqlite_master WHERE name='outbox'"), [["0"]])

        // NFD and NFC «йис» really are two distinct rows to SQLite even
        // though Swift's == would call them the same string.
        let both = raw { db in
            SQL.int(db, "SELECT COUNT(*) FROM user_word WHERE word IN ('\(nfdYis)', 'йис')")
        }
        XCTAssertEqual(both, 2, "Byte-distinct canonical equivalents must coexist pre-migration")
    }

    // MARK: - The migration, end to end

    func testTheRealEntryPointMigratesTheFixtureCorrectly() throws {
        let store = try XCTUnwrap(LearnedWords(directory: dir))
        XCTAssertEqual(store.migrationOutcome, .ready)
        XCTAssertFalse(store.isReadOnly)

        XCTAssertEqual(rawRows("SELECT value FROM meta WHERE key='schema_version'"), [["2"]])

        // Every word, canonical, with counters merged and nothing lost:
        //   кӏвал   = кӏвал(3,1) + кlвал(2,1), newest last_used wins
        //   йис     = NFD(3,0) + NFC(1,1), the OTHER merge direction
        //   чӏукӏ  = чіукі(4,1) + чӏукӏ(2,1)
        //   кӏарах = repaired homoglyphs, no twin, counters intact
        XCTAssertEqual(rawRows("SELECT word, count, picked, last_used FROM user_word ORDER BY word"), [
            ["зи", "9", "0", "1700000050"],
            ["йис", "4", "1", "1700000800"],
            ["кӏарах", "7", "0", "1700000600"],
            ["кӏвал", "5", "2", "1700000500"],
            ["хайи", "5", "2", "1700000100"],
            ["цӏийи", "6", "3", "1700000900"],
            ["чӏукӏ", "6", "2", "1700000400"],
        ])

        // Bigrams: both-sides repair merges into the canonical pair; the
        // NFD side normalizes without a twin; ordinary pairs untouched.
        XCTAssertEqual(rawRows("SELECT prev, word, count, last_used FROM user_bigram ORDER BY prev, word"), [
            ["зи", "хайи", "4", "1700000100"],
            ["йис", "зи", "2", "1700000700"],
            ["хайи", "цӏийи", "2", "1700000900"],
            ["чӏукӏ", "кӏвал", "5", "1700000400"],
        ])

        // Markers: moved where the migration moved them, untouched elsewhere.
        XCTAssertEqual(rawRows("SELECT key, value FROM meta ORDER BY key"), [
            ["filters_version", "1"],
            ["normalization_version", "\(Normalization.version)"],
            ["palochka_fixed", "1"],
            ["schema_version", "2"],
            ["total_events", "37"],
        ])

        XCTAssertEqual(rawRows("SELECT COUNT(*) FROM outbox"), [["0"]],
                       "The upgrade sweeps no history into the queue")

        // And the store actually works on the migrated data.
        XCTAssertEqual(store.suggestions(for: "кӏва", previous: nil), ["кӏвал"])
        XCTAssertTrue(store.isRecognized("чӏукӏ"))
    }

    func testEveryStoredValueIsCanonicalAfterMigration() throws {
        _ = try XCTUnwrap(LearnedWords(directory: dir))
        let tokens = rawRows("SELECT word FROM user_word").map { $0[0] }
            + rawRows("SELECT prev FROM user_bigram").map { $0[0] }
            + rawRows("SELECT word FROM user_bigram").map { $0[0] }
        for token in tokens {
            XCTAssertTrue(Normalization.isCanonical(token), "\(token) is not canonical")
        }
    }

    func testRunningTheMigrationAgainChangesNothing() throws {
        _ = try XCTUnwrap(LearnedWords(directory: dir))
        let afterFirst = logicalDump()
        XCTAssertFalse(afterFirst.isEmpty)

        for _ in 0..<3 {
            let store = try XCTUnwrap(LearnedWords(directory: dir))
            XCTAssertEqual(store.migrationOutcome, .ready)
        }

        XCTAssertEqual(logicalDump(), afterFirst,
                       "Reopening must be a fixed point: no re-merging, no marker "
                       + "churn, no counter drift")
    }
}
