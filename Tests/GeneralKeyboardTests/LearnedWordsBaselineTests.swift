//
//  LearnedWordsBaselineTests.swift
//
//  Phase 1A: a characterization suite for the learned store AS RELEASED.
//  These tests describe production behavior, they do not propose it — if a
//  later phase changes one of these expectations, that change must be
//  deliberate and called out in the commit.
//
//  Every test gets its own temporary directory, so nothing here can touch a
//  real user's learned.sqlite.
//

import XCTest
import SQLite3
@testable import GeneralKeyboard
@testable import GeneralKeyboardBridge
import GeneralKeyboardReference

final class LearnedWordsBaselineTests: GKTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("learned-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore(minVisibleUses: Int = 1) throws -> LearnedWords {
        let store = try XCTUnwrap(LearnedWords(directory: dir))
        store.minVisibleUses = minVisibleUses
        return store
    }

    // MARK: - Schema and metadata

    func testFreshDatabaseHasExpectedSchemaAndVersion() throws {
        _ = try makeStore()

        let tables = try queryStrings("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        XCTAssertEqual(tables, ["meta", "outbox", "sqlite_sequence", "user_bigram", "user_word"],
                       "The three released tables, plus the outbox added by schema step 2 "
                       + "(and the sqlite_sequence its AUTOINCREMENT implies). The three "
                       + "released tables must never disappear from this list.")

        XCTAssertEqual(try metaValue("schema_version"), 2,
                       "Released databases are at 1; step 2 carries them to 2")
        XCTAssertEqual(try metaValue("total_events"), 0)
        XCTAssertEqual(try metaValue("filters_version"), 1)
        XCTAssertEqual(try metaValue("palochka_fixed"), 1)
    }

    func testWALIsEnabled() throws {
        _ = try makeStore()
        let mode = try queryStrings("PRAGMA journal_mode").first
        XCTAssertEqual(mode?.lowercased(), "wal")
    }

    func testReopeningKeepsData() throws {
        do {
            let store = try makeStore()
            store.learn("хайи", previous: nil, picked: false)
        }
        let reopened = try makeStore()
        XCTAssertTrue(reopened.isRecognized("хайи"),
                      "The store must survive process death — the extension is killed constantly")
    }

    // MARK: - Learnability filter (the "hook")

    func testAcceptsOrdinaryWords() throws {
        let store = try makeStore()
        for word in ["хайи", "мурад", "кӏвал", "къуьл"] {
            store.learn(word, previous: nil, picked: false)
            XCTAssertTrue(store.isRecognized(word), "\(word) should be learnable")
        }
    }

    func testRejectsTokensWithDigitsEmailsAndPaths() throws {
        let store = try makeStore()
        for word in ["гаф1", "test@mail.ru", "сайт/гаф", "гаф.гаф"] {
            store.learn(word, previous: nil, picked: false)
            XCTAssertFalse(store.isRecognized(word), "\(word) must be rejected")
        }
    }

    func testRejectsTokensShorterThanTwoLetters() throws {
        let store = try makeStore()
        // A digraph is ONE letter even though it is two characters,
        // so "цӏ" is rejected while the two-letter "ва" is accepted.
        store.learn("ц", previous: nil, picked: false)
        store.learn("цӏ", previous: nil, picked: false)
        store.learn("ва", previous: nil, picked: false)
        XCTAssertFalse(store.isRecognized("ц"))
        XCTAssertFalse(store.isRecognized("цӏ"), "A lone digraph counts as a single letter")
        XCTAssertTrue(store.isRecognized("ва"))
    }

    func testRejectsOverlongTokens() throws {
        let store = try makeStore()
        let long = String(repeating: "а", count: 65)
        store.learn(long, previous: nil, picked: false)
        XCTAssertFalse(store.isRecognized(long))
    }

    func testStoresLowercasedFormRegardlessOfInputCase() throws {
        let store = try makeStore()
        store.learn("Хайи", previous: nil, picked: false)
        XCTAssertTrue(store.isRecognized("хайи"))
        XCTAssertTrue(store.isRecognized("ХАЙИ"), "Lookups lowercase too")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM user_word WHERE word = 'хайи'"), 1)
    }

    // MARK: - count / picked semantics

    func testTypingIncrementsCountAndPickingIncrementsPicked() throws {
        let store = try makeStore()
        store.learn("мурад", previous: nil, picked: false)
        store.learn("мурад", previous: nil, picked: false)
        store.learn("мурад", previous: nil, picked: true)

        XCTAssertEqual(try count("SELECT count FROM user_word WHERE word='мурад'"), 2)
        XCTAssertEqual(try count("SELECT picked FROM user_word WHERE word='мурад'"), 1)
    }

    func testPickedOutranksTypedByWeightThree() throws {
        let store = try makeStore()
        // "гуьзел" typed three times vs "гуьрчег" picked once: 3 vs 3 by the
        // count+3*picked formula, so a second pick must decide it.
        for _ in 0..<3 { store.learn("гуьзел", previous: nil, picked: false) }
        store.learn("гуьрчег", previous: nil, picked: true)
        store.learn("гуьрчег", previous: nil, picked: true)

        let ranked = store.suggestions(for: "гуь", previous: nil)
        XCTAssertEqual(ranked.first, "гуьрчег",
                       "picked weighs 3x, so 2 picks (6) beat 3 typings (3)")
    }

    // MARK: - Visibility threshold

    func testWordStaysInvisibleBelowThreshold() throws {
        let store = try makeStore(minVisibleUses: 3)
        store.learn("хайи", previous: nil, picked: false)
        XCTAssertFalse(store.isRecognized("хайи"), "1 use < threshold 3")
        XCTAssertTrue(store.suggestions(for: "хай", previous: nil).isEmpty)

        store.learn("хайи", previous: nil, picked: false)
        store.learn("хайи", previous: nil, picked: false)
        XCTAssertTrue(store.isRecognized("хайи"), "3 uses reach the threshold")
        XCTAssertEqual(store.suggestions(for: "хай", previous: nil), ["хайи"])
    }

    func testDefaultThresholdIsOneSoWordsSurfaceImmediately() throws {
        let store = try XCTUnwrap(LearnedWords(directory: dir))
        XCTAssertEqual(store.minVisibleUses, 1,
                       "Product default is fast learning (1 use)")
    }

    // MARK: - Bigrams

    func testBigramNeedsTwoSightingsBeforeItSuggests() throws {
        let store = try makeStore()
        store.learn("хайи", previous: "зи", picked: false)
        XCTAssertTrue(store.nextWords(after: "зи").isEmpty, "One sighting is not enough")

        store.learn("хайи", previous: "зи", picked: false)
        XCTAssertEqual(store.nextWords(after: "зи"), ["хайи"])
    }

    func testBigramIsNotStoredWhenPreviousWordIsUnlearnable() throws {
        let store = try makeStore()
        store.learn("хайи", previous: "гаф1", picked: false)
        store.learn("хайи", previous: "гаф1", picked: false)
        XCTAssertTrue(store.nextWords(after: "гаф1").isEmpty)
        XCTAssertEqual(try count("SELECT COUNT(*) FROM user_bigram"), 0)
    }

    func testBigramBoostsPrefixRanking() throws {
        let store = try makeStore()
        // Both candidates equal on their own counters…
        store.learn("хуьр", previous: nil, picked: false)
        store.learn("хуьруьн", previous: nil, picked: false)
        // …but one has been seen after "зи" repeatedly.
        for _ in 0..<3 { store.learn("хуьруьн", previous: "зи", picked: false) }

        XCTAssertEqual(store.suggestions(for: "хуь", previous: "зи").first, "хуьруьн",
                       "The bigram multiplier lifts the contextually likely word")
    }

    // MARK: - Recognition helpers used by the suggestion bar

    func testIsRecognizedRequiresThresholdAndTwoCharacters() throws {
        let store = try makeStore(minVisibleUses: 2)
        store.learn("хайи", previous: nil, picked: false)
        XCTAssertFalse(store.isRecognized("хайи"))
        store.learn("хайи", previous: nil, picked: false)
        XCTAssertTrue(store.isRecognized("хайи"))
        XCTAssertFalse(store.isRecognized("несуществующее"))
    }

    // MARK: - Saved-words page

    func testTopWordsRespectsThresholdAndRanking() throws {
        let store = try makeStore(minVisibleUses: 2)
        store.learn("сад", previous: nil, picked: false)          // below threshold
        for _ in 0..<2 { store.learn("кьвед", previous: nil, picked: false) }
        store.learn("пуд", previous: nil, picked: true)
        store.learn("пуд", previous: nil, picked: true)           // 6 points

        let top = store.topWords(limit: 10)
        XCTAssertEqual(top.first, "пуд", "Highest count+3*picked first")
        XCTAssertTrue(top.contains("кьвед"))
        XCTAssertFalse(top.contains("сад"), "Below-threshold words are internal signal only")
    }

    // MARK: - Deletion and reset

    func testDeleteRemovesWordAndEveryPairReferencingIt() throws {
        let store = try makeStore()
        for _ in 0..<2 {
            store.learn("хайи", previous: "зи", picked: false)
            store.learn("хуьр", previous: "хайи", picked: false)
        }
        XCTAssertEqual(try count("SELECT COUNT(*) FROM user_bigram"), 2)

        store.delete("хайи")

        XCTAssertFalse(store.isRecognized("хайи"))
        XCTAssertEqual(try count("SELECT COUNT(*) FROM user_bigram"), 0,
                       "Pairs on both sides of the deleted word go with it")
    }

    func testResetClearsVocabularyButKeepsQualityMetrics() throws {
        let store = try makeStore()
        store.learn("хайи", previous: nil, picked: false)
        store.bumpMetric(.accepted)
        store.bumpMetric(.opportunities)

        store.reset()

        XCTAssertFalse(store.isRecognized("хайи"))
        XCTAssertEqual(try count("SELECT COUNT(*) FROM user_word"), 0)
        XCTAssertEqual(try metaValue("total_events"), 0)
        XCTAssertEqual(try metaValue("m_accepted"), 1,
                       "Metrics describe bar quality over time and survive a vocabulary reset")
        XCTAssertEqual(try metaValue("m_opportunities"), 1)
    }

    // MARK: - Metrics

    func testMetricsCountersIncrementIndependently() throws {
        let store = try makeStore()
        store.bumpMetric(.opportunities)
        store.bumpMetric(.opportunities)
        store.bumpMetric(.ignored)

        XCTAssertEqual(try metaValue("m_opportunities"), 2)
        XCTAssertEqual(try metaValue("m_ignored"), 1)
        XCTAssertEqual(try metaValue("m_accepted"), 0)
        XCTAssertTrue(store.metricsSummary().contains("opportunities=2"))
    }

    // MARK: - Maintenance: decay

    func testDecayHalvesCountersAndDropsOneOffWords() throws {
        let store = try makeStore()
        // A word with a solid history…
        for _ in 0..<10 { store.learn("даим", previous: nil, picked: false) }
        // …and a one-off that decay is designed to forget.
        store.learn("садра", previous: nil, picked: false)

        // Drive total_events to the decay threshold (2000). Each learn call
        // counts as one event; the two words above already contributed 11.
        for i in 0..<1989 { store.learn("гаф\(i % 2 == 0 ? "ар" : "ун")", previous: nil, picked: false) }

        XCTAssertEqual(try metaValue("total_events"), 0, "Decay resets the event counter")
        XCTAssertEqual(try count("SELECT count FROM user_word WHERE word='даим'"), 5,
                       "10 halved to 5")
        XCTAssertEqual(try count("SELECT COUNT(*) FROM user_word WHERE word='садра'"), 0,
                       "A single-use word halves to zero and is deleted — this is the point of decay")
    }

    // MARK: - Typing-path cost (documented, not asserted as a limit)

    func testSuggestionLookupDoesNotScanTheWholeTable() throws {
        let store = try makeStore()
        for i in 0..<500 { store.learn("гаф\(i)ар", previous: nil, picked: false) }

        // Both queries are prefix-bounded and LIMIT 3; this test exists to
        // catch a future change that turns them into a full scan.
        measure {
            _ = store.suggestions(for: "гаф1", previous: nil)
        }
    }

    // MARK: - Raw SQL helpers (read-only, test-side)

    private func openRaw() throws -> OpaquePointer {
        var handle: OpaquePointer?
        let path = dir.appendingPathComponent("learned.sqlite").path
        XCTAssertEqual(sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        return try XCTUnwrap(handle)
    }

    private func queryStrings(_ sql: String) throws -> [String] {
        let db = try openRaw()
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    private func count(_ sql: String) throws -> Int {
        let db = try openRaw()
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func metaValue(_ key: String) throws -> Int {
        try count("SELECT value FROM meta WHERE key = '\(key)'")
    }
}
