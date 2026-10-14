//
//  DefinitionTests.swift
//  GeneralKeyboardTests
//
//  The definition boundary itself: the reference definition is valid and
//  installed, capability rules hold for one- and two-style keyboards, the
//  new conventions default to the released behavior, the profile-driven
//  normalization equals the released implementation, and no engine
//  source spells language data.
//

import XCTest
import SQLite3
import UIKit
@testable import GeneralKeyboard
import GeneralKeyboardReference

final class ReferenceDefinitionTests: GKTestCase {

    private var d: KeyboardDefinition { KeyboardDefinition.current }

    func testTheReferenceDefinitionIsInstalledAndValid() {
        XCTAssertTrue(KeyboardDefinition.isInstalled)
        XCTAssertEqual(d.validationErrors(), [])
        XCTAssertEqual(d.data.appGroupID, "group.org.lekitech.generalkeyboard")
        XCTAssertEqual(d.data.wordsArtifact, "reference_words")
        XCTAssertEqual(d.data.bigramsArtifact, "reference_bigrams")
        XCTAssertEqual(WordSuggestions.artifactName, "reference_words")
        XCTAssertEqual(StaticBigrams.artifactName, "reference_bigrams")
        XCTAssertEqual(d.data.diagnosticsSubsystem, "ReferenceKeyboard")
    }

    func testTwoStyleCapabilities() {
        XCTAssertEqual(d.layout.styles.map(\.id), [.threeRow, .fourRow])
        XCTAssertEqual(LayoutStyle.allCases, [.threeRow, .fourRow])
        XCTAssertEqual(d.layout.defaultStyle, .threeRow)
        XCTAssertTrue(d.layout.showsSelector)
        XCTAssertEqual(d.layout.persistenceKey, "layoutStyle")
        XCTAssertEqual(d.layout.resolve("fourRow"), .fourRow)
        XCTAssertEqual(d.layout.resolve(nil), .threeRow)
        XCTAssertEqual(d.layout.resolve("classic"), .threeRow)
    }

    func testOneStyleKeyboards() {
        let four = ReferenceDefinition.fourRowOnly.layout
        XCTAssertEqual(four.validationErrors(), [])
        XCTAssertFalse(four.showsSelector, "one style: no selector even when requested")
        XCTAssertEqual(four.resolve("threeRow"), .fourRow, "unsupported persisted value falls back")
        XCTAssertEqual(four.resolve(nil), .fourRow)
        XCTAssertEqual(four.spec(for: .threeRow).id, .fourRow)

        let three = ReferenceDefinition.threeRowOnly.layout
        XCTAssertEqual(three.validationErrors(), [])
        XCTAssertFalse(three.showsSelector)
        XCTAssertEqual(three.resolve("fourRow"), .threeRow)

        var broken = three
        broken.defaultStyle = .fourRow
        XCTAssertFalse(broken.validationErrors().isEmpty, "the default must be offered")
        broken.styles = []
        XCTAssertFalse(broken.validationErrors().isEmpty, "a keyboard needs a style")
    }

    func testProductStylesCanBeNamedFreely() {
        let custom = LayoutStyle(rawValue: "classic")
        var caps = d.layout
        caps.styles = [LayoutStyleSpec(id: custom, letterRows: d.layout.styles[0].letterRows,
                                       numberRows: d.layout.styles[0].numberRows,
                                       symbolRows: d.layout.styles[0].symbolRows,
                                       callouts: [:], metrics: d.layout.styles[0].metrics,
                                       settingsTitle: "", settingsSubtitle: "")]
        caps.defaultStyle = custom
        caps.persistenceKey = "layoutVariant"
        XCTAssertEqual(caps.validationErrors(), [])
        XCTAssertEqual(caps.resolve("classic"), custom)
        XCTAssertEqual(caps.resolve("topRow"), custom)
    }

    func testConventionDefaultsReproduceTheReleasedConstants() {
        let released = CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ".,!?;:\"'()[]{}—–-"))
        XCTAssertEqual(TextConventions.defaultWordSeparators, released)
        XCTAssertEqual(d.text.wordSeparators, released)
        XCTAssertEqual(d.text.unknownWordOpenQuote, "\u{00AB}")
        XCTAssertEqual(d.text.unknownWordCloseQuote, "\u{00BB}")
        XCTAssertEqual(d.text.visiblePalochka, "\u{04C0}")
        XCTAssertEqual(d.text.caseNeutral, ["\u{04C0}", "\u{04CF}"])
    }

    func testStringsWithArguments() {
        XCTAssertEqual(d.strings.deleteWordQuestion("рагӀи"), "“рагӀи” гилдизеищ?")
        XCTAssertEqual(d.strings.aboutByline("1.0.0"), "Версия 1.0.0 · LekiTech")
        XCTAssertEqual(KeyboardSettings.LearnSpeed.allCases.map { d.strings.learnUses($0.minUses) },
                       ["1 нухалъ", "3 нухалъ", "5 нухалъ"])
        XCTAssertEqual(KeyboardSettings.CalloutDelay.allCases.map { d.strings.calloutDuration($0.seconds) },
                       ["0,2 с", "0,3 с", "0,45 с"])
    }

    func testEmojiCatalogIDs() {
        XCTAssertEqual(EmojiCatalog.categoryIDs,
                       ["smileys", "nature", "food", "activity", "travel", "objects", "symbols", "flags"])
        XCTAssertEqual(Set(d.emojiCategoryTitles.keys), Set(EmojiCatalog.categoryIDs))
    }

    func testTheEngineCatalogResolvesInTheModuleBundle() throws {
        let bundle = GeneralKeyboardResources.bundle
        let ru = try XCTUnwrap(bundle.path(forResource: "ru", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(ru.localizedString(forKey: "layout", value: "MISSING", table: nil), "раскладка")
        XCTAssertEqual(ru.localizedString(forKey: "after 3 uses", value: "MISSING", table: nil),
                       "после 3 использований")
        let en = try XCTUnwrap(bundle.path(forResource: "en", ofType: "lproj").flatMap(Bundle.init(path:)))
        XCTAssertEqual(en.localizedString(forKey: "Match the system", value: "MISSING", table: nil),
                       "Match the system")
    }

    // MARK: - Normalization profile

    func testTheProfileIsTheBuiltInDagestanianCyrillicV1() {
        XCTAssertEqual(d.normalization, .dagestanianCyrillicV1)
        XCTAssertEqual(d.normalization.id, "dagestanian-cyrillic")
        XCTAssertEqual(Normalization.version, 1)
    }

    func testDeclaredDigraphTailsMatchTheLayoutDerivations() {
        var fromCallouts = Set<Character>()
        for alternates in d.layout.calloutUnion.values {
            for alternate in alternates where alternate.count == 2 {
                if let tail = alternate.lowercased().last { fromCallouts.insert(tail) }
            }
        }
        XCTAssertEqual(fromCallouts, d.normalization.digraphTails)
        XCTAssertEqual(fromCallouts.union(["ъ"]), d.normalization.digraphTails)
        XCTAssertEqual(LegacyNormalizationB6A5C53.digraphTails, Normalization.digraphTails)
    }

    // MARK: - Side by side with the released implementation

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Fixtures/ReferenceArtifacts")

    private static func column(_ sql: String, file: String) -> [String] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(fixtures.appendingPathComponent(file).path, &db,
                              SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let t = sqlite3_column_text(stmt, 0) { out.append(String(cString: t)) }
        }
        return out
    }

    /// Deterministic adversarial strings: Cyrillic, both palochkas, every
    /// lookalike and homoglyph, digits, separators, whitespace, combining
    /// marks, controls and invisibles.
    private static func fuzzCorpus(count: Int) -> [String] {
        let pool: [String] = Array("абвгдеёжзийклмнопрстуфхцчшщъыьэюяАБВГДЕЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯ")
            .map(String.init) + [
            "\u{04CF}", "\u{04C0}", "I", "l", "i", "\u{0406}", "\u{0456}", "1", "|", "!",
            "a", "c", "e", "o", "p", "x", "y", "k", "m", "t", "b", "h", "z", "Q",
            "0", "7", "@", "/", ".", "-", " ", "\u{00A0}", "\t", "\n",
            "\u{0301}", "\u{0306}", "\u{001F}", "\u{200D}", "\u{200E}", "⅚", "Ⅻ", "Σ", "İ", "й",
        ]
        var state: UInt64 = 0x9E3779B97F4A7C15
        func next() -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int(truncatingIfNeeded: state >> 33)
        }
        return (0..<count).map { _ in
            (0..<(1 + next() % 12)).map { _ in pool[next() % pool.count] }.joined()
        }
    }

    func testProfileNormalizationIsIdenticalToTheReleasedOne() {
        let words = Self.column("SELECT word FROM words", file: "reference_words.sqlite")
        let prevs = Self.column("SELECT prev FROM bigrams", file: "reference_bigrams.sqlite")
        let nexts = Self.column("SELECT word FROM bigrams", file: "reference_bigrams.sqlite")
        XCTAssertEqual(words.count, 5_000)
        XCTAssertEqual(prevs.count, 5_013)
        let inputs = words + prevs + nexts + Self.fuzzCorpus(count: 60_000)
            + words.map { $0.uppercased() }
        var mismatches: [String] = []
        for input in inputs {
            let old = LegacyNormalizationB6A5C53.self
            if Array(Normalization.canonical(input).unicodeScalars)
                != Array(old.canonical(input).unicodeScalars)
                || Normalization.isCanonical(input) != old.isCanonical(input)
                || Normalization.isValidToken(input) != old.isValidToken(input)
                || Normalization.letterCount(input) != old.letterCount(input) {
                mismatches.append(input)
                if mismatches.count >= 10 { break }
            }
        }
        XCTAssertEqual(mismatches, [], "\(inputs.count) inputs compared")
    }

    func testTheShippedReferenceArtifactsAreWellFormed() throws {
        let words = try XCTUnwrap(WordSuggestions(databaseURL:
            Self.fixtures.appendingPathComponent("reference_words.sqlite")))
        let meta = try XCTUnwrap(words.metadata)
        XCTAssertEqual(meta.artifact, "reference_words")
        XCTAssertEqual(meta.rowCount, 5_000)
        XCTAssertEqual(meta.normalizationVersion, Normalization.version)
        let bigrams = try XCTUnwrap(StaticBigrams(databaseURL:
            Self.fixtures.appendingPathComponent("reference_bigrams.sqlite")))
        XCTAssertEqual(bigrams.metadata?.artifact, "reference_bigrams")
        XCTAssertFalse(bigrams.nextWords(after: "вуго").isEmpty)
    }
}

// MARK: - Engine neutrality

final class EngineNeutralityTests: GKTestCase {

    private static let sources = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources")

    private static func swiftFiles(in module: String) -> [URL] {
        let root = sources.appendingPathComponent(module)
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        return (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    /// No string literal in the engine or the bridge contains a Cyrillic
    /// letter. Sanctioned: the built-in normalization profile and the frozen
    /// historical palochka migration.
    func testEngineSourcesSpellNoLanguageData() throws {
        let literal = try NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*""#)
        var offenders: [String] = []
        let files = Self.swiftFiles(in: "GeneralKeyboard") + Self.swiftFiles(in: "GeneralKeyboardBridge")
        XCTAssertGreaterThan(files.count, 15)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in source.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                let range = NSRange(code.startIndex..., in: code)
                for match in literal.matches(in: code, range: range) {
                    let text = String(code[Range(match.range, in: code)!])
                    if text.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) {
                        offenders.append("\(file.lastPathComponent):\(number + 1): \(text)")
                    }
                }
            }
        }
        let sanctioned = offenders.filter {
            $0.hasPrefix("NormalizationProfile.swift:")
                || ($0.hasPrefix("Migrations.swift:") && $0.hasSuffix(": \"\u{04CF}\""))
        }
        XCTAssertEqual(offenders, sanctioned)
        XCTAssertEqual(offenders.filter { $0.hasPrefix("Migrations.swift:") }.count, 1)
    }

    /// The engine never names a product: no type, file or identifier from
    /// a downstream keyboard appears in code (comments may cite history).
    func testEngineSourcesReferenceNoProduct() throws {
        var offenders: [String] = []
        for file in Self.swiftFiles(in: "GeneralKeyboard") + Self.swiftFiles(in: "GeneralKeyboardBridge") {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in source.components(separatedBy: "\n").enumerated() {
                let code = line.components(separatedBy: "//").first ?? line
                if code.range(of: #"\b(Avar|Lezgi|avar_|lezgi_|avarkeyboard|lezgikeyboard)"#,
                              options: .regularExpression) != nil {
                    offenders.append("\(file.lastPathComponent):\(number + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [])
    }
}

// MARK: - The released normalization, frozen verbatim (b6a5c53) for comparison

enum LegacyNormalizationB6A5C53 {

    /// Bumped when the rules below change. Artifacts record the version
    /// they were built with, so a mismatch is detectable rather than silent.
    static let version = 1

    /// ӏ CYRILLIC SMALL LETTER PALOCHKA (U+04CF) — the one true palochka.
    static let palochka: Character = "ӏ"

    /// Characters users and source corpora substitute for the palochka.
    /// Repaired only inside tokens that contain Cyrillic, so a genuine
    /// Latin borrowing keeps its "i".
    /// Deliberately excludes the digit 1 and the pipe: this keyboard types
    /// real digits, and `isLearnable` rejects digit-bearing tokens, so
    /// repairing «гаф1» into «гафӏ» would turn a token the store must
    /// refuse into one it accepts. Corpus sources that use 1-as-palochka
    /// are a preprocessing concern, not part of the canonical contract —
    /// and the shipped dictionary contains no such row.
    private static let palochkaLookalikes: Set<Character> = [
        "I", "l", "i",
        "І",   // U+0406 CYRILLIC CAPITAL LETTER BYELORUSSIAN-UKRAINIAN I
        "і",   // U+0456 its lowercase — found 34 times in the shipped dictionary
        "Ӏ",   // U+04C0 uppercase palochka
    ]

    /// Latin letters visually identical to a Cyrillic letter. Applied only
    /// to otherwise-Cyrillic tokens.
    private static let latinToCyrillic: [Character: Character] = [
        "a": "а", "c": "с", "e": "е", "o": "о", "p": "р", "x": "х",
        "y": "у", "k": "к", "m": "м", "t": "т", "b": "ь", "h": "н",
    ]

    /// A digraph tail extends the previous letter instead of counting as its
    /// own, so "цӏ" and "къ" are ONE letter. Derived from the layout's
    /// long-press alternates so the rule has a single source. The layout
    /// stores callouts with the typed capital palochka (Ӏ, U+04C0), while
    /// counting always runs on canonical (lowercased) tokens — so each tail
    /// is lowercased on the way into the set.
    static let digraphTails: Set<Character> = {
        var tails = Set<Character>()
        for alternates in KeyboardLayout.callouts.values {
            for alternate in alternates where alternate.count == 2 {
                if let tail = alternate.lowercased().last { tails.insert(tail) }
            }
        }
        tails.insert("ъ")   // the hard sign is a tail even without a callout
        return tails
    }()

    private static func containsCyrillic(_ token: String) -> Bool {
        token.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
    }

    /// The canonical form. Idempotent by construction:
    /// `canonical(canonical(x)) == canonical(x)`.
    static func canonical(_ token: String) -> String {
        // 1. NFC, so a decomposed «й» (и + combining breve) is the same word
        //    as the precomposed U+0439.
        var result = token.precomposedStringWithCanonicalMapping
        // 2. Trim. Internal whitespace makes a token invalid, not repairable.
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // 3. Lowercase — this alone maps Ӏ (U+04C0) to ӏ (U+04CF).
        result = result.lowercased()
        // 4-5. Repair lookalikes, but only where the token is Cyrillic.
        if containsCyrillic(result) {
            result = String(result.map { ch in
                if palochkaLookalikes.contains(ch) { return palochka }
                return latinToCyrillic[ch] ?? ch
            })
        }
        // 6. NFC again so the function is idempotent whatever the repairs did.
        return result.precomposedStringWithCanonicalMapping
    }

    /// Whether a token is ALREADY in canonical form, compared by scalars.
    ///
    /// Swift's `==` is canonical-equivalent, so `decomposed == precomposed`
    /// is true even though SQLite — which compares bytes — treats them as
    /// two different rows. Any code deciding whether a stored value needs
    /// rewriting must use this, not `==`.
    static func isCanonical(_ token: String) -> Bool {
        Array(canonical(token).unicodeScalars) == Array(token.unicodeScalars)
    }

    /// Letters in a canonical token, digraphs counted as one.
    static func letterCount(_ token: String) -> Int {
        token.reduce(0) { digraphTails.contains($1) ? $0 : $0 + 1 }
    }

    /// Whether a canonical token may be stored, learned, or contributed.
    ///
    /// This is the CONTRACT definition. It is intentionally not wired into
    /// the released learning path yet: `LearnedWords.isLearnable` keeps its
    /// own equivalent rules, and unifying them changes what gets learned,
    /// which needs its own migration and review.
    static func isValidToken(_ token: String) -> Bool {
        // Scalars, not Characters: Python's len() counts code points, and
        // the two halves of the contract must measure length identically.
        // On canonical (NFC) Avar text the two counts agree anyway; they
        // diverge only on combining-mark sequences, exactly where an
        // implicit disagreement would hide.
        guard !token.isEmpty, token.unicodeScalars.count <= 64 else { return false }
        guard !token.contains(where: \.isWhitespace) else { return false }
        guard !token.contains(where: \.isNumber) else { return false }
        guard !token.contains("@"), !token.contains("/"), !token.contains(".") else { return false }
        guard !token.contains(where: { $0.isASCII && $0.isLetter }) else { return false }
        // No control or format characters. Controls (Cc) include U+001F,
        // which the contribution outbox uses to join bigram keys — a token
        // that could carry it would make that encoding ambiguous. Formats
        // (Cf) are the invisibles — ZWJ, ZWNJ, bidi marks — that would let
        // two identical-looking tokens be different rows.
        guard !token.unicodeScalars.contains(where: { scalar in
            let category = scalar.properties.generalCategory
            return category == .control || category == .format
        }) else { return false }
        return letterCount(token) >= 2
    }
}
