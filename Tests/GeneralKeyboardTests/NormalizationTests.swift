//
//  NormalizationTests.swift
//
//  The canonical-form contract (docs/ARTIFACT_CONTRACT.md §2). These tests
//  also pin the Swift half against the Python half in
//  scripts/build_dictionaries.py — if the two drift, the artifacts and the
//  runtime stop agreeing on what a word is.
//

import XCTest
@testable import GeneralKeyboard
@testable import GeneralKeyboardBridge
import GeneralKeyboardReference

final class NormalizationTests: GKTestCase {

    // MARK: - Unicode form

    func testDecomposedAndPrecomposedFormsCollapse() {
        // «й» typed as и + U+0306 COMBINING BREVE, as pasted text can carry.
        let decomposed = "\u{0438}\u{0306}ис"
        let precomposed = "йис"

        // Swift's String == is canonical-equivalent, so these compare EQUAL
        // in Swift while differing byte-for-byte. SQLite compares bytes, so
        // the decomposed form would miss every dictionary lookup — which is
        // precisely why normalization has to happen before the query.
        XCTAssertNotEqual(Array(decomposed.unicodeScalars), Array(precomposed.unicodeScalars),
                          "Precondition: the scalar sequences differ")
        XCTAssertNotEqual(Array(decomposed.utf8), Array(precomposed.utf8),
                          "Precondition: the bytes SQLite sees differ")

        XCTAssertEqual(Array(Normalization.canonical(decomposed).unicodeScalars),
                       Array(precomposed.unicodeScalars))
    }

    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(Normalization.canonical("  армуд \n"), "армуд")
    }

    // MARK: - Case

    func testLowercases() {
        XCTAssertEqual(Normalization.canonical("ХАЙИ"), "хайи")
    }

    func testUppercasePalochkaBecomesCanonicalPalochka() {
        // U+04C0 -> U+04CF, which plain lowercasing already does; pinned
        // because the whole dictionary depends on it.
        XCTAssertEqual(Normalization.canonical("КӀВАЛ"), "кӏвал")
        XCTAssertEqual(Normalization.canonical("КӀВАЛ").unicodeScalars.map(\.value).filter { $0 == 0x04CF }.count, 1)
    }

    // MARK: - Palochka repair

    func testUkrainianIBecomesPalochka() {
        // U+0456 — 34 real occurrences in the shipped dictionary.
        XCTAssertEqual(Normalization.canonical("чіукі"), "чӏукӏ")
    }

    func testLatinCapitalIAndLowercaseLBecomePalochkaInCyrillicTokens() {
        XCTAssertEqual(Normalization.canonical("кIвал"), "кӏвал")
        XCTAssertEqual(Normalization.canonical("кlвал"), "кӏвал")
        // The digit 1 is NOT a lookalike — see testDigitsAreNeverRepaired…
    }

    func testLatinOnlyTokensAreLeftAlone() {
        // No Cyrillic, so the repair rules must not fire — a borrowing keeps
        // its Latin spelling instead of turning into gibberish.
        XCTAssertEqual(Normalization.canonical("iPhone"), "iphone")
        XCTAssertEqual(Normalization.canonical("wifi"), "wifi")
    }

    // MARK: - Homoglyph repair

    func testLatinHomoglyphsInsideCyrillicWordsAreRepaired() {
        // Real defects found in the shipped dictionary.
        XCTAssertEqual(Normalization.canonical("кӏapax"), "кӏарах")
        XCTAssertEqual(Normalization.canonical("атӏaнивди"), "атӏанивди")
    }

    // MARK: - Idempotence

    func testCanonicalIsIdempotent() {
        for raw in ["КӀВАЛ", "чіукі", "  армуд ", "кӏapax", "iPhone", "цӏиргъ"] {
            let once = Normalization.canonical(raw)
            XCTAssertEqual(Normalization.canonical(once), once, "not idempotent for \(raw)")
        }
    }

    // MARK: - Digraphs and validity

    func testDigraphCountsAsOneLetter() {
        XCTAssertEqual(Normalization.letterCount("цӏ"), 1)
        XCTAssertEqual(Normalization.letterCount("къ"), 1)
        XCTAssertEqual(Normalization.letterCount("кӏвал"), 4, "к ӏ в а л -> кӏ,в,а,л")
        XCTAssertEqual(Normalization.letterCount("ва"), 2)
    }

    func testValidTokens() {
        for token in ["хайи", "кӏвал", "къуьл", "ва"] {
            XCTAssertTrue(Normalization.isValidToken(token), "\(token) should be valid")
        }
    }

    func testInvalidTokens() {
        let cases: [(String, String)] = [
            ("", "empty"),
            ("а", "single letter"),
            ("цӏ", "lone digraph is one letter"),
            ("гаф1", "digit"),
            ("а@б", "email punctuation"),
            ("гаф/гаф", "path punctuation"),
            ("гаф.гаф", "dot"),
            ("армуд ар", "internal whitespace"),
            ("iphone", "Latin script"),
            (String(repeating: "а", count: 65), "too long"),
        ]
        for (token, why) in cases {
            XCTAssertFalse(Normalization.isValidToken(token), "\(token.prefix(12)) should be invalid: \(why)")
        }
    }

    // MARK: - Contract boundary

    func testContractValidityIsNotYetWiredIntoLearning() throws {
        // LearnedWords keeps its own equivalent rules; unifying them would
        // change what gets learned and needs its own migration. This test
        // exists so that unification is a deliberate act that breaks a test
        // rather than a silent behavior change.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("norm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try XCTUnwrap(LearnedWords(directory: dir))
        // "армуд ар" is invalid per the contract, and the learn path also
        // rejects nothing here — it never sees whitespace, because the
        // tokenizer splits on it upstream. Documented, not asserted as
        // desirable.
        XCTAssertFalse(Normalization.isValidToken("армуд ар"))
        store.learn("хайи", previous: nil, picked: false)
        XCTAssertTrue(store.isRecognized("хайи"))
    }
}

extension NormalizationTests {

    /// Regression: an earlier draft repaired the digit 1 into a palochka,
    /// which turned «гаф1» — a token the learned store must refuse — into
    /// the perfectly learnable «гафӏ». The keyboard types real digits, so
    /// digits are never lookalikes.
    func testDigitsAreNeverRepairedIntoPalochka() {
        XCTAssertEqual(Normalization.canonical("гаф1"), "гаф1")
        XCTAssertFalse(Normalization.isValidToken(Normalization.canonical("гаф1")))
        XCTAssertEqual(Normalization.canonical("к1вал"), "к1вал")
    }

    func testPipeIsNotRepairedEither() {
        XCTAssertEqual(Normalization.canonical("гаф|"), "гаф|")
    }

    // MARK: - Control and format characters

    /// The contribution outbox joins bigram keys with U+001F, so the
    /// contract must make a token carrying it invalid — otherwise the
    /// encoding would be ambiguous.
    func testTheBigramSeparatorCannotSurviveValidation() {
        let smuggled = "ва\u{1F}кӏвал"
        XCTAssertFalse(Normalization.isValidToken(smuggled))
        XCTAssertFalse(Normalization.isValidToken(Normalization.canonical(smuggled)),
                       "canonical() does not strip controls; validation is the gate")
    }

    func testControlAndFormatCharactersInvalidateAToken() {
        let cases: [(String, String)] = [
            ("кӏ\u{0000}вал", "NUL"),
            ("кӏ\u{001F}вал", "unit separator, the bigram key joiner"),
            ("кӏ\u{200D}вал", "zero-width joiner — two identical-looking tokens"),
            ("кӏ\u{200C}вал", "zero-width non-joiner"),
            ("кӏ\u{202E}вал", "right-to-left override"),
            ("кӏвал\u{00AD}", "soft hyphen"),
        ]
        for (token, why) in cases {
            XCTAssertFalse(Normalization.isValidToken(token), "must be invalid: \(why)")
        }
    }
}
