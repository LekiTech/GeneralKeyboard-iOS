//
//  PrefixRangeTests.swift
//
//  The prefix range is the one place where a clever query could silently
//  return the wrong words. These tests make "equivalent to LIKE over the
//  canonical dictionary" an enforced contract rather than an observation
//  about today's data — every case compares the range query against a LIKE
//  query executed over the same fixture.
//
//  Why the algorithm is correct, in one line: UTF-8 preserves code-point
//  order under byte comparison, and SQLite compares TEXT with BINARY
//  collation, so `word >= P AND word < P + U+10FFFF` selects exactly the
//  strings that begin with P — U+10FFFF being the largest scalar there is.
//

import XCTest
import SQLite3
@testable import GeneralKeyboard
@testable import GeneralKeyboardBridge
import GeneralKeyboardReference

final class PrefixRangeTests: GKTestCase {

    private var dir: URL!
    private var db: OpaquePointer?

    /// Words chosen to hit every boundary the range has to respect.
    private let corpus = [
        "кӏвал",        // ordinary word with a palochka
        "кӏвалах",      // longer word sharing that prefix
        "кӏв",          // exact match for the prefix itself
        "кӏ",           // lone digraph — shorter than the prefix
        "кь",           // sorts adjacent to кӏ; must never leak in
        "къ",
        "к",            // single letter
        "куьче",
        "йис",          // precomposed й
        "хуьр",
        "цӏиргъ",
        "\u{10FFFE}ы",  // a noncharacter well above anything real
        "я\u{10FFFD}",  // high scalar in the tail position
        "гаф_гаф",      // contains the LIKE wildcard `_`
        "гаф%гаф",      // contains the LIKE wildcard `%`
    ]

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("prefix-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("words.sqlite")
        XCTAssertEqual(sqlite3_open_v2(url.path, &db,
                                       SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE words(word TEXT PRIMARY KEY, base_score INTEGER NOT NULL DEFAULT 0) WITHOUT ROWID", nil, nil, nil)
        for word in corpus {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO words(word) VALUES(?1)", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, (word as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    override func tearDownWithError() throws {
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: - The two queries under comparison

    /// The shipped strategy: `[prefix, prefix + U+10FFFF)`.
    private func rangeQuery(_ prefix: String) -> [String] {
        var stmt: OpaquePointer?
        let sql = "SELECT word FROM words WHERE word >= ?1 AND word < ?2 ORDER BY word"
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (prefix as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, ((prefix + "\u{10FFFF}") as NSString).utf8String, -1, nil)
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    /// The released strategy, verbatim: unescaped `prefix || '%'`.
    private func likeQuery(_ prefix: String) -> [String] {
        var stmt: OpaquePointer?
        let sql = "SELECT word FROM words WHERE word LIKE ?1 ORDER BY word"
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, ((prefix + "%") as NSString).utf8String, -1, nil)
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
        }
        return out
    }

    private func assertEquivalent(_ prefix: String,
                                  _ message: String = "",
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(rangeQuery(prefix), likeQuery(prefix),
                       "range and LIKE disagree for \(prefix.debugDescription). \(message)",
                       file: file, line: line)
    }

    // MARK: - Ordinary prefixes

    func testOrdinaryCyrillicPrefix() {
        XCTAssertEqual(rangeQuery("куь"), ["куьче"])
        assertEquivalent("куь")
        assertEquivalent("х")
        assertEquivalent("йи")
    }

    func testPrefixContainingPalochka() {
        XCTAssertEqual(rangeQuery("кӏв"), ["кӏв", "кӏвал", "кӏвалах"],
                       "Exact match plus every longer word, and nothing from кь/къ")
        assertEquivalent("кӏв")
        assertEquivalent("кӏ")
        assertEquivalent("цӏ")
    }

    func testAdjacentDigraphsDoNotLeak() {
        // ӏ (U+04CF), ь (U+044C) and ъ (U+044A) are neighbours in the
        // alphabet; a sloppy upper bound would pull кь and къ into кӏ.
        XCTAssertFalse(rangeQuery("кӏ").contains("кь"))
        XCTAssertFalse(rangeQuery("кӏ").contains("къ"))
        XCTAssertEqual(rangeQuery("кь"), ["кь"])
    }

    func testSingleCharacterPrefixMatchesItselfAndDescendants() {
        let result = rangeQuery("к")
        XCTAssertTrue(result.contains("к"), "The exact match must be included")
        XCTAssertTrue(result.contains("кӏвалах"))
        XCTAssertTrue(result.contains("куьче"))
        assertEquivalent("к")
    }

    // MARK: - Normalization at the boundary

    func testDecomposedPrefixMatchesAfterNormalization() throws {
        // The reader normalizes before querying; raw decomposed input would
        // miss, since SQLite compares bytes.
        let reader = try XCTUnwrap(
            WordSuggestions(databaseURL: dir.appendingPathComponent("words.sqlite")))
        let decomposed = "\u{0438}\u{0306}"          // и + combining breve = й
        XCTAssertEqual(reader.suggestions(for: decomposed), ["йис"])
        XCTAssertTrue(rangeQuery(decomposed).isEmpty,
                      "Precondition: without normalization the raw bytes find nothing")
    }

    func testUppercaseAndLookalikePrefixesReachTheSameRows() throws {
        let reader = try XCTUnwrap(
            WordSuggestions(databaseURL: dir.appendingPathComponent("words.sqlite")))
        // «к1в» is deliberately absent: digits are not palochka lookalikes,
        // because this keyboard types real digits (see
        // NormalizationTests.testDigitsAreNeverRepairedIntoPalochka).
        for prefix in ["КӀВ", "кIв", "кlв", "  кӏв "] {
            XCTAssertEqual(reader.suggestions(for: prefix).sorted(), ["кӏв", "кӏвал", "кӏвалах"],
                           "\(prefix) should canonicalize to кӏв")
        }
    }

    // MARK: - Prefixes with no successor

    func testPrefixWithNoLongerWords() {
        XCTAssertEqual(rangeQuery("хуьр"), ["хуьр"], "Exact match only, no descendants")
        assertEquivalent("хуьр")
    }

    func testPrefixMatchingNothingAtAll() {
        XCTAssertTrue(rangeQuery("яяя").isEmpty)
        assertEquivalent("яяя")
    }

    func testPrefixAtTheTopOfTheAlphabet() {
        // «я» is the last Cyrillic letter here; the upper bound must still
        // be well-formed and must not wrap.
        XCTAssertEqual(rangeQuery("я"), ["я\u{10FFFD}"])
        assertEquivalent("я")
    }

    // MARK: - Near the maximum scalar

    func testHighScalarsInsideWords() {
        // A word whose tail holds U+10FFFD must still be found by its
        // ordinary prefix — the bound is U+10FFFF, strictly greater.
        XCTAssertTrue(rangeQuery("я").contains("я\u{10FFFD}"))
        assertEquivalent("я")
    }

    func testPrefixThatIsItselfAHighScalar() {
        // U+10FFFE sorts above every real character; the query must behave,
        // not misbehave, even though such a prefix cannot be typed.
        XCTAssertEqual(rangeQuery("\u{10FFFE}"), ["\u{10FFFE}ы"])
        assertEquivalent("\u{10FFFE}")
    }

    func testDocumentedExclusion() {
        // The single string the range cannot match: a word that continues
        // with U+10FFFF itself, since the bound is exclusive. U+10FFFF is a
        // permanent noncharacter and never appears in text — recorded here
        // so the limitation is known rather than discovered.
        var stmt: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO words(word) VALUES(?1)", -1, &stmt, nil)
        sqlite3_bind_text(stmt, 1, ("зз\u{10FFFF}" as NSString).utf8String, -1, nil)
        sqlite3_step(stmt)
        sqlite3_finalize(stmt)

        XCTAssertTrue(rangeQuery("зз").isEmpty, "Known and accepted exclusion")
        XCTAssertEqual(likeQuery("зз"), ["зз\u{10FFFF}"], "LIKE would have matched it")
    }

    // MARK: - Where the range is STRICTLY better than LIKE

    func testUnderscoreIsALiteralInTheRangeButAWildcardInLike() {
        // The released query interpolated the prefix into LIKE unescaped,
        // so a typed `_` matched ANY character. `_` is reachable from the
        // symbols page and is not a word separator, so it could enter a
        // composed word. The range treats it as the literal it is.
        XCTAssertEqual(rangeQuery("гаф_"), ["гаф_гаф"])
        XCTAssertEqual(likeQuery("гаф_").sorted(), ["гаф%гаф", "гаф_гаф"],
                       "LIKE's `_` wildcard also matched the `%` row — a latent bug")
    }

    func testPercentIsALiteralInTheRangeButAWildcardInLike() {
        XCTAssertEqual(rangeQuery("гаф%"), ["гаф%гаф"])
        XCTAssertEqual(likeQuery("гаф%").sorted(), ["гаф%гаф", "гаф_гаф"],
                       "LIKE's `%` matched everything after `гаф`")
    }

}
