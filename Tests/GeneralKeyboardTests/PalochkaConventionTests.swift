//
//  PalochkaConventionTests.swift
//  GeneralKeyboardTests
//
//  The palochka convention: user-facing text carries Ӏ U+04C0 (keys,
//  long-press options, inserted text, every suggestion), and lookup keys
//  carry its Unicode case folding ӏ U+04CF (normalization, the bundled
//  artifacts, the learned store). docs/engine/ARTIFACT_CONTRACT.md §2a.
//

import XCTest
@testable import GeneralKeyboard
@testable import GeneralKeyboardBridge
import GeneralKeyboardReference

@MainActor
final class PalochkaConventionTests: GKTestCase {

    private let visible = "\u{04C0}"
    private let lookupKey = "\u{04CF}"

    private func chars(_ row: [KeyCap]) -> [String] {
        row.compactMap { if case .character(let s) = $0 { return s } else { return nil } }
    }

    private func typing(_ caps: [String], style: LayoutStyle = .threeRow,
                        shift: ShiftState = .off) -> String {
        let m = KeyboardTestEnvironment.freshModel(style: style)
        m.shiftState = shift
        let proxy = MockTextDocumentProxy()
        for cap in caps { m.handleKey(.character(cap), proxy: proxy) }
        return proxy.before
    }

    // MARK: - Typed input

    func testThePalochkaKeyInsertsTheVisiblePalochkaInEveryShiftState() {
        let key = chars(KeyboardLayout.letterRows(style: .threeRow)[1])[1]
        XCTAssertEqual(key, visible)
        for shift in [ShiftState.off, .once, .capsLock] {
            XCTAssertEqual(typing([key], shift: shift), visible, "\(shift)")
        }
    }

    func testDigraphKeysInsertTheVisiblePalochkaInEveryShiftState() {
        let key = chars(KeyboardLayout.letterRows(style: .fourRow)[0])[3]
        XCTAssertEqual(key, "к" + visible)
        XCTAssertEqual(typing([key], style: .fourRow, shift: .off), "к" + visible)
        XCTAssertEqual(typing([key], style: .fourRow, shift: .once), "К" + visible)
        XCTAssertEqual(typing([key], style: .fourRow, shift: .capsLock), "К" + visible)
    }

    func testTheLookupPalochkaIsNeverTyped() {
        // A key or option that still carries ӏ U+04CF inserts the visible form
        XCTAssertEqual(typing(["ц" + lookupKey, "и"]), "ц" + visible + "и")
    }

    func testEveryKeyAndCalloutUsesTheVisiblePalochka() {
        for style in LayoutStyle.allCases {
            var strings = KeyboardLayout.letterRows(style: style).flatMap(chars)
            for (key, options) in KeyboardLayout.callouts(style: style) {
                strings.append(key)
                strings.append(contentsOf: options)
            }
            for s in strings {
                XCTAssertFalse(s.contains(lookupKey), "\(style): \(s) carries ӏ U+04CF")
                for latin in ["I", "l", "\u{0406}", "\u{0456}"] where s.contains(latin) {
                    XCTFail("\(style): \(s) carries a palochka lookalike")
                }
            }
        }
    }

    func testCalloutLookupKeepsTheVisiblePalochka() {
        let text = KeyboardDefinition.current.text
        let lower = { (s: String) in text.visibleLowercased(s, canonicalPalochka: Normalization.palochka) }
        XCTAssertEqual(lower("К" + visible), "к" + visible)
        XCTAssertEqual(lower(visible), visible)
        XCTAssertNotNil(KeyboardLayout.callouts(style: .fourRow)[lower("К" + visible)])
        XCTAssertNotNil(KeyboardLayout.callouts(style: .threeRow)[lower(visible)])
        // Without a visible palochka it is plain lowercasing
        let plain = TextConventions(visiblePalochka: nil, caseNeutral: [])
        XCTAssertEqual(plain.visibleLowercased("К" + visible, canonicalPalochka: Normalization.palochka),
                       "к" + lookupKey)
    }

    func testCalloutKeysMayCarryTheVisiblePalochka() {
        XCTAssertEqual(KeyboardDefinition.current.validationErrors(), [])
        var layout = KeyboardDefinition.current.layout
        var spec = layout.styles[0]
        spec.callouts["К" + visible] = ["ы"]
        layout.styles[0] = spec
        XCTAssertEqual(layout.validationErrors(lowercase: { s in
            KeyboardDefinition.current.text.visibleLowercased(s, canonicalPalochka: Normalization.palochka)
        }).count, 1, "an uppercase callout key is still rejected")
    }

    // MARK: - Suggestions and learned words

    func testSuggestionsCarryTheVisiblePalochkaWhateverWasTyped() {
        for typed in ["ц" + visible, "ц" + lookupKey, "цI", "цl"] {
            let m = KeyboardTestEnvironment.freshModel(learnedWords: ["ц\(lookupKey)ияб"])
            m.shiftState = .off
            let proxy = MockTextDocumentProxy(before: "Салам \(typed)")
            m.syncComposedWord(proxy: proxy)
            m.updateSuggestions(proxy: proxy)
            let candidates = m.suggestions.filter { $0 != typed }   // the literal is the user's text
            XCTAssertFalse(candidates.isEmpty, typed)
            for candidate in candidates {
                XCTAssertFalse(candidate.contains(lookupKey), "\(typed): \(candidate)")
            }
            XCTAssertTrue(candidates.contains("ц\(visible)ияб"), "\(typed): \(candidates)")
        }
    }

    func testLearnedWordsKeepTheirLookupKeysAndShowTheVisiblePalochka() {
        let m = KeyboardTestEnvironment.freshModel()
        let store = LearnedWords()
        // Learning text typed with Ӏ stores the folded key ӏ, so stores written
        // before this convention and after it hold the same rows
        store?.learn("ц\(visible)ияб", previous: nil, picked: false)
        store?.learn("ц\(visible)ияб", previous: nil, picked: false)
        XCTAssertTrue(store?.topWords(limit: 10).contains("ц\(lookupKey)ияб") == true)
        XCTAssertFalse(store?.topWords(limit: 10).contains { $0.contains(self.visible) } == true)
        XCTAssertTrue(store?.isRecognized("ц\(visible)ияб") == true)
        XCTAssertTrue(m.savedWords().allSatisfy { !$0.contains(lookupKey) })
    }

    func testNextWordSuggestionsCarryTheVisiblePalochka() {
        // A learned pair stored with lookup keys: «авар» → «мацӏалъул»
        let m = KeyboardTestEnvironment.freshModel()
        let store = LearnedWords()
        for _ in 0..<3 { store?.learn("мац\(lookupKey)алъул", previous: "авар", picked: false) }
        m.shiftState = .off
        let proxy = MockTextDocumentProxy()
        for letter in "авар" { m.handleKey(.character(String(letter)), proxy: proxy) }
        m.handleKey(.space, proxy: proxy)
        m.updateSuggestions(proxy: proxy)
        XCTAssertTrue(m.suggestions.contains("мац\(visible)алъул"), "\(m.suggestions)")
        XCTAssertFalse(m.suggestions.contains { $0.contains(lookupKey) }, "\(m.suggestions)")
    }
}
