//
//  RankingIntegrationTests.swift
//
//  The precedence contract (docs/ARTIFACT_CONTRACT.md §4) and the
//  regression requirement: with an EMPTY static-bigram artifact the
//  candidate order must be exactly what the released keyboard produced.
//
//  These tests exercise the same ordering rule `KeyboardModel` applies,
//  against synthetic fixtures. KeyboardModel itself needs a live
//  UITextDocumentProxy, so the rule is verified here at the level where it
//  is decided — the dictionary tier and its static reorder — rather than
//  through the UIKit surface.
//

import XCTest
import SQLite3
@testable import GeneralKeyboard
@testable import GeneralKeyboardBridge
import GeneralKeyboardReference

final class RankingIntegrationTests: GKTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ranking-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// The exact rule `KeyboardModel.rankedDictionaryWords` applies: a
    /// stable sort on static weight alone, absent pairs weighing 0.
    private func reorder(_ words: [String],
                         previous: String?,
                         using bigrams: StaticBigrams?) -> [String] {
        guard let previous, let bigrams, !bigrams.isEmpty, words.count > 1 else { return words }
        let weights = bigrams.weights(after: previous, candidates: words)
        guard !weights.isEmpty else { return words }
        return words.enumerated()
            .sorted { lhs, rhs in
                let lw = weights[lhs.element] ?? 0
                let rw = weights[rhs.element] ?? 0
                return lw == rw ? lhs.offset < rhs.offset : lw > rw
            }
            .map(\.element)
    }

    // MARK: - Fixtures

    private func makeWords(_ words: [(String, Int)]) throws -> WordSuggestions {
        let url = dir.appendingPathComponent("words.sqlite")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db,
                                       SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE words(word TEXT PRIMARY KEY, base_score INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID", nil, nil, nil)
        for (word, score) in words {
            sqlite3_exec(db, "INSERT INTO words(word, base_score) VALUES('\(word)', \(score))", nil, nil, nil)
        }
        sqlite3_exec(db, "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)", nil, nil, nil)
        for (k, v) in [("artifact", "reference_words"), ("schema_version", "1"),
                       ("content_version", "1"), ("normalization_version", "1"),
                       ("min_reader_schema", "1"), ("row_count", "\(words.count)")] {
            sqlite3_exec(db, "INSERT INTO meta VALUES('\(k)','\(v)')", nil, nil, nil)
        }
        sqlite3_close(db)
        return try XCTUnwrap(WordSuggestions(databaseURL: url))
    }

    private func makeBigrams(_ pairs: [(String, String, Int)], name: String) throws -> StaticBigrams {
        let url = dir.appendingPathComponent(name)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db,
                                       SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE bigrams(prev TEXT NOT NULL, word TEXT NOT NULL, weight INTEGER NOT NULL, PRIMARY KEY(prev, word)) WITHOUT ROWID", nil, nil, nil)
        for (prev, word, weight) in pairs {
            sqlite3_exec(db, "INSERT INTO bigrams VALUES('\(prev)','\(word)',\(weight))", nil, nil, nil)
        }
        sqlite3_exec(db, "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)", nil, nil, nil)
        for (k, v) in [("artifact", "reference_bigrams"), ("schema_version", "1"),
                       ("content_version", "1"), ("normalization_version", "1"),
                       ("min_reader_schema", "1"), ("row_count", "\(pairs.count)")] {
            sqlite3_exec(db, "INSERT INTO meta VALUES('\(k)','\(v)')", nil, nil, nil)
        }
        sqlite3_close(db)
        return try XCTUnwrap(StaticBigrams(databaseURL: url))
    }

    // MARK: - The regression requirement

    func testEmptyBigramArtifactPreservesTheReleasedOrder() throws {
        let words = try makeWords([("хуьр", 0), ("хуьруьн", 0), ("хуьрер", 0)])
        let empty = try makeBigrams([], name: "empty.sqlite")

        let baseline = words.suggestions(for: "хуьр")
        let withEmptyArtifact = reorder(baseline, previous: "зи", using: empty)

        XCTAssertEqual(withEmptyArtifact, baseline,
                       "An empty static artifact must not perturb a single position")
        XCTAssertEqual(baseline, ["хуьр", "хуьрер", "хуьруьн"],
                       "…and that order is the released one: shortest first")
    }

    func testMissingBigramArtifactIsAlsoHarmless() throws {
        let words = try makeWords([("хуьр", 0), ("хуьруьн", 0)])
        let baseline = words.suggestions(for: "хуьр")
        XCTAssertEqual(reorder(baseline, previous: "зи", using: nil), baseline)
        XCTAssertNil(StaticBigrams(databaseURL: dir.appendingPathComponent("nope.sqlite")),
                     "A missing artifact yields no reader, and the caller degrades")
    }

    func testNoPreviousWordMeansNoStaticInfluence() throws {
        let words = try makeWords([("хуьр", 0), ("хуьруьн", 0)])
        let loaded = try makeBigrams([("зи", "хуьруьн", 9)], name: "loaded.sqlite")
        let baseline = words.suggestions(for: "хуьр")
        XCTAssertEqual(reorder(baseline, previous: nil, using: loaded), baseline)
    }

    // MARK: - What static context actually does

    func testStaticContextReordersTheDictionaryTier() throws {
        let words = try makeWords([("хуьр", 0), ("хуьруьн", 0), ("хуьрер", 0)])
        let loaded = try makeBigrams([("зи", "хуьруьн", 9)], name: "loaded.sqlite")

        let baseline = words.suggestions(for: "хуьр")
        XCTAssertEqual(baseline.first, "хуьр", "Precondition: shortest leads without context")

        let contextual = reorder(baseline, previous: "зи", using: loaded)
        XCTAssertEqual(contextual.first, "хуьруьн", "The corpus pair promotes its word")
        XCTAssertEqual(Set(contextual), Set(baseline), "Reordering only — nothing added or lost")
    }

    func testUnweightedCandidatesKeepTheirRelativeOrder() throws {
        let words = try makeWords([("хуьр", 0), ("хуьруьн", 0), ("хуьрер", 0)])
        let loaded = try makeBigrams([("зи", "хуьруьн", 9)], name: "loaded.sqlite")

        let contextual = reorder(words.suggestions(for: "хуьр"), previous: "зи", using: loaded)
        XCTAssertEqual(contextual, ["хуьруьн", "хуьр", "хуьрер"],
                       "The stable sort leaves the untouched pair in SQL order")
    }

    func testBaseScoreAndStaticWeightAreNeverSummed() throws {
        // хуьр carries a large base_score; хуьруьн carries a small static
        // weight. If the scales were added, хуьр would win. They are not:
        // static weight is the primary key of the dictionary tier's order,
        // base_score only breaks ties among unweighted rows.
        let words = try makeWords([("хуьр", 1000), ("хуьруьн", 0)])
        let loaded = try makeBigrams([("зи", "хуьруьн", 1)], name: "loaded.sqlite")

        let baseline = words.suggestions(for: "хуьр")
        XCTAssertEqual(baseline.first, "хуьр", "base_score leads without context")

        let contextual = reorder(baseline, previous: "зи", using: loaded)
        XCTAssertEqual(contextual.first, "хуьруьн",
                       "A weight of 1 beats a base_score of 1000 — different scales, never mixed")
    }

    // MARK: - Personal learning is never overridden

    func testPersonalCandidatesStayAheadOfStaticallyPromotedOnes() throws {
        let learnedDir = dir.appendingPathComponent("learned")
        try FileManager.default.createDirectory(at: learnedDir, withIntermediateDirectories: true)
        let store = try XCTUnwrap(LearnedWords(directory: learnedDir))
        store.learn("хуьрекар", previous: nil, picked: false)

        let words = try makeWords([("хуьр", 0), ("хуьруьн", 0)])
        let loaded = try makeBigrams([("зи", "хуьруьн", 99)], name: "loaded.sqlite")

        // The merge KeyboardModel performs: personal tier, then the
        // (statically reordered) dictionary tier.
        let personal = store.suggestions(for: "хуьр", previous: "зи")
        let dictionary = reorder(words.suggestions(for: "хуьр"), previous: "зи", using: loaded)
        var merged = personal
        for word in dictionary where !merged.contains(word) { merged.append(word) }

        XCTAssertEqual(personal, ["хуьрекар"], "Precondition: the user's own word is a candidate")
        XCTAssertEqual(merged.first, "хуьрекар",
                       "A corpus weight of 99 must not displace a word this user typed")
        XCTAssertEqual(merged[1], "хуьруьн", "Static context still orders the tier below")
    }
}
