//
//  BundledArtifactTests.swift
//
//  The bundled artifact readers, exercised against SYNTHETIC fixtures only.
//  No production frequencies or bigrams are invented here — the fixtures
//  exist to prove ordering, fallback and precedence mechanics, and their
//  contents are meaningless as linguistic data.
//

import XCTest
import SQLite3
@testable import GeneralKeyboard
@testable import GeneralKeyboardBridge
import GeneralKeyboardReference

final class BundledArtifactTests: GKTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("artifact-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - Fixture builders

    /// Builds a words artifact. `words` maps word → base_score.
    @discardableResult
    private func makeWordsFixture(_ words: [(String, Int)],
                                  minReaderSchema: Int = 1,
                                  withMetadata: Bool = true,
                                  withBaseScore: Bool = true,
                                  name: String = "words.sqlite") throws -> URL {
        let url = dir.appendingPathComponent(name)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db,
                                       SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }

        if withBaseScore {
            exec(db, "CREATE TABLE words(word TEXT PRIMARY KEY, base_score INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID")
            for (word, score) in words {
                exec(db, "INSERT INTO words(word, base_score) VALUES('\(word)', \(score))")
            }
        } else {
            // The pre-metadata artifact shape, as shipped in 1.2.0.
            exec(db, "CREATE TABLE words(word TEXT PRIMARY KEY ASC)")
            for (word, _) in words {
                exec(db, "INSERT INTO words(word) VALUES('\(word)')")
            }
        }
        if withMetadata {
            writeMeta(db, kind: "reference_words", rows: words.count, minReaderSchema: minReaderSchema)
        }
        return url
    }

    @discardableResult
    private func makeBigramsFixture(_ pairs: [(String, String, Int)],
                                    name: String = "bigrams.sqlite") throws -> URL {
        let url = dir.appendingPathComponent(name)
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(url.path, &db,
                                       SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        exec(db, """
            CREATE TABLE bigrams(prev TEXT NOT NULL, word TEXT NOT NULL,
                                 weight INTEGER NOT NULL,
                                 PRIMARY KEY(prev, word)) WITHOUT ROWID
            """)
        for (prev, word, weight) in pairs {
            exec(db, "INSERT INTO bigrams(prev, word, weight) VALUES('\(prev)','\(word)',\(weight))")
        }
        writeMeta(db, kind: "reference_bigrams", rows: pairs.count, minReaderSchema: 1)
        return url
    }

    private func writeMeta(_ db: OpaquePointer?, kind: String, rows: Int, minReaderSchema: Int) {
        exec(db, "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL)")
        let rowsToWrite = [
            ("artifact", kind), ("schema_version", "1"), ("content_version", "1"),
            ("normalization_version", "1"), ("min_reader_schema", "\(minReaderSchema)"),
            ("row_count", "\(rows)"),
        ]
        for (k, v) in rowsToWrite {
            exec(db, "INSERT INTO meta(key, value) VALUES('\(k)','\(v)')")
        }
    }

    private func exec(_ db: OpaquePointer?, _ sql: String) {
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK, "failed: \(sql)")
    }

    // MARK: - Metadata

    func testReadsArtifactMetadata() throws {
        let url = try makeWordsFixture([("хайи", 0)])
        let reader = try XCTUnwrap(WordSuggestions(databaseURL: url))
        let meta = try XCTUnwrap(reader.metadata)
        XCTAssertEqual(meta.artifact, "reference_words")
        XCTAssertEqual(meta.schemaVersion, 1)
        XCTAssertEqual(meta.normalizationVersion, Normalization.version)
        XCTAssertEqual(meta.rowCount, 1)
    }

    func testArtifactFromTheFutureIsRefused() throws {
        let url = try makeWordsFixture([("хайи", 0)], minReaderSchema: 99)
        XCTAssertNil(WordSuggestions(databaseURL: url),
                     "A wrong reading of the dictionary is worse than no dictionary")
    }

    func testPreMetadataArtifactStillOpens() throws {
        // The 1.2.0 dictionary had neither meta nor base_score.
        let url = try makeWordsFixture([("хайи", 0), ("хайибур", 0)],
                                       withMetadata: false, withBaseScore: false)
        let reader = try XCTUnwrap(WordSuggestions(databaseURL: url))
        XCTAssertNil(reader.metadata)
        XCTAssertEqual(reader.suggestions(for: "хай"), ["хайи", "хайибур"],
                       "Falls back to length ordering, exactly as released")
    }

    // MARK: - Prefix lookup

    func testPrefixLookupIsBoundedAndOrderedByLengthWhenScoresAreNeutral() throws {
        let url = try makeWordsFixture([
            ("кӏвал", 0), ("кӏвалах", 0), ("кӏве", 0), ("гаф", 0),
        ])
        let reader = try XCTUnwrap(WordSuggestions(databaseURL: url))
        XCTAssertEqual(reader.suggestions(for: "кӏв"), ["кӏве", "кӏвал", "кӏвалах"],
                       "All base scores neutral -> shortest first, the released order")
        XCTAssertEqual(reader.suggestions(for: "гаф"), ["гаф"])
        XCTAssertTrue(reader.suggestions(for: "яяя").isEmpty)
    }

    func testBaseScoreOutranksLength() throws {
        let url = try makeWordsFixture([
            ("кӏве", 0), ("кӏвал", 10), ("кӏвалах", 0),
        ])
        let reader = try XCTUnwrap(WordSuggestions(databaseURL: url))
        XCTAssertEqual(reader.suggestions(for: "кӏв").first, "кӏвал",
                       "A scored word leads even though it is not the shortest")
    }

    func testLookupNormalizesItsInput() throws {
        let url = try makeWordsFixture([("кӏвал", 0)])
        let reader = try XCTUnwrap(WordSuggestions(databaseURL: url))
        // Uppercase, Latin-I palochka, and a stray space all reach the same row.
        XCTAssertEqual(reader.suggestions(for: "КӀВ"), ["кӏвал"])
        XCTAssertEqual(reader.suggestions(for: "кIв"), ["кӏвал"])
        XCTAssertTrue(reader.contains(" КӀВАЛ "))
    }

    func testPrefixRangeDoesNotLeakIntoNeighbouringWords() throws {
        let url = try makeWordsFixture([("кӏвал", 0), ("кьил", 0), ("к", 0)])
        let reader = try XCTUnwrap(WordSuggestions(databaseURL: url))
        XCTAssertEqual(reader.suggestions(for: "кӏ"), ["кӏвал"],
                       "The range upper bound must not spill into кь…")
    }

    // MARK: - Static bigrams

    func testEmptyBigramArtifactYieldsNothingAndCostsNoQuery() throws {
        let url = try makeBigramsFixture([])
        let bigrams = try XCTUnwrap(StaticBigrams(databaseURL: url))
        XCTAssertTrue(bigrams.isEmpty)
        XCTAssertTrue(bigrams.weights(after: "зи", candidates: ["хуьр", "хуьруьн"]).isEmpty)
        XCTAssertTrue(bigrams.nextWords(after: "зи").isEmpty)
    }

    func testWeightsAreReturnedForKnownPairsOnly() throws {
        let url = try makeBigramsFixture([("зи", "хуьруьн", 7), ("зи", "стха", 3)])
        let bigrams = try XCTUnwrap(StaticBigrams(databaseURL: url))
        let weights = bigrams.weights(after: "зи", candidates: ["хуьр", "хуьруьн", "стха"])
        XCTAssertEqual(weights["хуьруьн"], 7)
        XCTAssertEqual(weights["стха"], 3)
        XCTAssertNil(weights["хуьр"], "Unknown pairs simply have no entry")
    }

    func testNextWordsAreOrderedByWeight() throws {
        let url = try makeBigramsFixture([("зи", "стха", 3), ("зи", "хуьруьн", 9)])
        let bigrams = try XCTUnwrap(StaticBigrams(databaseURL: url))
        XCTAssertEqual(bigrams.nextWords(after: "зи"), ["хуьруьн", "стха"])
    }

    func testBigramLookupNormalizesBothSides() throws {
        let url = try makeBigramsFixture([("зи", "кӏвал", 5)])
        let bigrams = try XCTUnwrap(StaticBigrams(databaseURL: url))
        XCTAssertEqual(bigrams.weights(after: "ЗИ", candidates: ["кIвал"])["кӏвал"], 5)
    }

    // MARK: - The shipped artifacts

}
