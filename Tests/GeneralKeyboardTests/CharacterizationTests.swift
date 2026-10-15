//
//  CharacterizationTests.swift
//  GeneralKeyboardTests
//
//  The persisted state and engine constants, characterized on the
//  released Avar keyboard (AvarKeyboard-iOS b6a5c53) and carried over with
//  the engine. Run with the reference definition, whose fixture data is
//  Avar's, so every expectation is unchanged. A failure means the engine's
//  behavior changed. Rendered strings are pinned by ViewSnapshotTests.
//

import XCTest
import CryptoKit
import SQLite3
import UIKit
@testable import GeneralKeyboard
@testable import GeneralKeyboardBridge
import GeneralKeyboardReference

// MARK: - KeyboardSettings persistence

final class SettingsPersistenceCharacterizationTests: GKTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "gk.characterization.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private static let allKeys: Set<String> = [
        "set_wordSuggestions", "set_nextWordSuggestions", "set_autoSpaceAfterSuggestion",
        "set_doubleSpacePeriod", "set_spaceCursor", "set_spaceLabel",
        "set_learnSpeed", "set_calloutDelay", "set_theme",
    ]

    func testDefaultsWhenNothingIsStored() {
        let s = KeyboardSettings.load(from: defaults)
        XCTAssertTrue(s.wordSuggestions)
        XCTAssertTrue(s.nextWordSuggestions)
        XCTAssertTrue(s.autoSpaceAfterSuggestion)
        XCTAssertTrue(s.doubleSpacePeriod)
        XCTAssertTrue(s.spaceCursor)
        XCTAssertTrue(s.spaceLabel)
        XCTAssertEqual(s.learnSpeed, .fast)
        XCTAssertEqual(s.calloutDelay, .normal)
        XCTAssertEqual(s.theme, .system)
        XCTAssertEqual(s, KeyboardSettings())
    }

    func testSaveWritesExactlyTheNinePersistedKeys() throws {
        var s = KeyboardSettings()
        s.wordSuggestions = false
        s.spaceLabel = false
        s.learnSpeed = .conservative
        s.calloutDelay = .long
        s.theme = .dark
        s.save(to: defaults)

        let stored = try XCTUnwrap(defaults.persistentDomain(forName: suiteName))
        XCTAssertEqual(Set(stored.keys), Self.allKeys)
        XCTAssertEqual(stored["set_wordSuggestions"] as? Bool, false)
        XCTAssertEqual(stored["set_nextWordSuggestions"] as? Bool, true)
        XCTAssertEqual(stored["set_autoSpaceAfterSuggestion"] as? Bool, true)
        XCTAssertEqual(stored["set_doubleSpacePeriod"] as? Bool, true)
        XCTAssertEqual(stored["set_spaceCursor"] as? Bool, true)
        XCTAssertEqual(stored["set_spaceLabel"] as? Bool, false)
        XCTAssertEqual(stored["set_learnSpeed"] as? String, "conservative")
        XCTAssertEqual(stored["set_calloutDelay"] as? String, "long")
        XCTAssertEqual(stored["set_theme"] as? String, "dark")
    }

    func testRawValuesAndTheirMeaningsAreStable() {
        XCTAssertEqual(KeyboardSettings.LearnSpeed.allCases.map(\.rawValue),
                       ["fast", "normal", "conservative"])
        XCTAssertEqual(KeyboardSettings.LearnSpeed.allCases.map(\.minUses), [1, 3, 5])
        XCTAssertEqual(KeyboardSettings.CalloutDelay.allCases.map(\.rawValue),
                       ["short", "normal", "long"])
        XCTAssertEqual(KeyboardSettings.CalloutDelay.allCases.map(\.seconds), [0.2, 0.3, 0.45])
        XCTAssertEqual(KeyboardSettings.Theme.allCases.map(\.rawValue),
                       ["system", "light", "dark"])
    }

    func testLoadReadsEveryStoredValue() {
        for key in Self.allKeys where key != "set_learnSpeed" && key != "set_calloutDelay"
            && key != "set_theme" {
            defaults.set(false, forKey: key)
        }
        defaults.set("normal", forKey: "set_learnSpeed")
        defaults.set("short", forKey: "set_calloutDelay")
        defaults.set("light", forKey: "set_theme")
        let s = KeyboardSettings.load(from: defaults)
        XCTAssertFalse(s.wordSuggestions || s.nextWordSuggestions || s.autoSpaceAfterSuggestion
                       || s.doubleSpacePeriod || s.spaceCursor || s.spaceLabel)
        XCTAssertEqual(s.learnSpeed, .normal)
        XCTAssertEqual(s.calloutDelay, .short)
        XCTAssertEqual(s.theme, .light)
    }

    func testUnreadableValuesFallBackToDefaults() {
        defaults.set("turbo", forKey: "set_learnSpeed")
        defaults.set(3, forKey: "set_calloutDelay")
        defaults.set("sepia", forKey: "set_theme")
        defaults.set("no", forKey: "set_spaceLabel")
        // NSNumber bridging: an integer 0 is honored as false.
        defaults.set(0, forKey: "set_spaceCursor")
        let s = KeyboardSettings.load(from: defaults)
        XCTAssertEqual(s.learnSpeed, .fast)
        XCTAssertEqual(s.calloutDelay, .normal)
        XCTAssertEqual(s.theme, .system)
        XCTAssertTrue(s.spaceLabel)
        XCTAssertFalse(s.spaceCursor)
    }
}

// MARK: - KeyboardModel persisted state, layout composition, presentation

@MainActor
final class KeyboardModelCharacterizationTests: GKTestCase {

    private func model(style: LayoutStyle? = .threeRow, recentEmojis: [String] = [],
                       learnedWords: [String] = [], settings: KeyboardSettings? = nil)
        -> KeyboardModel {
        KeyboardTestEnvironment.freshModel(style: style, recentEmojis: recentEmojis,
                                           learnedWords: learnedWords, settings: settings)
    }

    func testLayoutStyleIsReadFromTheLayoutStyleKey() {
        XCTAssertEqual(model(style: .fourRow).layoutStyle, .fourRow)
        XCTAssertEqual(model(style: .threeRow).layoutStyle, .threeRow)
        XCTAssertEqual(model(style: nil).layoutStyle, .threeRow, "absent key falls back")
        KeyboardTestEnvironment.resetPersistentState()
        UserDefaults.standard.set("twoRow", forKey: "layoutStyle")
        XCTAssertEqual(KeyboardModel().layoutStyle, .threeRow, "unknown value falls back")
    }

    func testChoosingAStylePersistsItsRawValue() {
        let m = model(style: nil)
        XCTAssertNil(UserDefaults.standard.object(forKey: "layoutStyle"),
                     "the default is not written until the user chooses")
        m.setLayoutStyle(.fourRow)
        XCTAssertEqual(UserDefaults.standard.string(forKey: "layoutStyle"), "fourRow")
        XCTAssertEqual(KeyboardModel().layoutStyle, .fourRow)
    }

    func testSettingsComeFromStandardDefaultsAndAChangePersistsAllNine() {
        let m = model(settings: .with { $0.theme = .dark; $0.learnSpeed = .normal })
        XCTAssertEqual(m.settings.theme, .dark)
        XCTAssertEqual(m.settings.learnSpeed, .normal)
        KeyboardTestEnvironment.resetPersistentState()
        let fresh = KeyboardModel()
        fresh.updateSettings { $0.spaceCursor = false }
        let d = UserDefaults.standard
        XCTAssertEqual(d.object(forKey: "set_spaceCursor") as? Bool, false)
        XCTAssertEqual(d.string(forKey: "set_learnSpeed"), "fast")
        XCTAssertEqual(d.string(forKey: "set_theme"), "system")
        XCTAssertEqual(d.object(forKey: "set_wordSuggestions") as? Bool, true)
    }

    func testRecentEmojisAreMostRecentFirstDedupedAndCappedAt24() {
        let m = model(recentEmojis: ["😀", "❤️"])
        XCTAssertEqual(m.recentEmojis, ["😀", "❤️"])
        m.recordRecentEmoji("❤️")
        XCTAssertEqual(UserDefaults.standard.stringArray(forKey: "recentEmojis"), ["❤️", "😀"])
        let many = (0..<30).map { String(UnicodeScalar(0x1F600 + $0)!) }
        for emoji in many { m.recordRecentEmoji(emoji) }
        let stored = UserDefaults.standard.stringArray(forKey: "recentEmojis") ?? []
        XCTAssertEqual(stored.count, 24)
        XCTAssertEqual(stored.first, many.last)
        XCTAssertEqual(KeyboardModel().recentEmojis, stored)
    }

    func testBottomRowsPerPage() {
        let m = model(style: .threeRow)
        m.page = .letters
        XCTAssertEqual(m.rows(needsGlobe: false).last, [.numbers, .settings, .emoji, .space, .return])
        XCTAssertEqual(m.rows(needsGlobe: true).last,
                       [.numbers, .settings, .emoji, .globe, .space, .return])
        XCTAssertEqual(m.rows(needsGlobe: false).count, 4)
        m.page = .numbers
        XCTAssertEqual(m.rows(needsGlobe: false).last, [.letters, .space, .return])
        XCTAssertEqual(m.rows(needsGlobe: true).last, [.letters, .globe, .space, .return])
        m.page = .symbols
        XCTAssertEqual(m.rows(needsGlobe: false).last, [.letters, .space, .return])
        m.page = .emoji
        XCTAssertEqual(m.rows(needsGlobe: false), [])
        m.setLayoutStyle(.fourRow)
        m.page = .letters
        XCTAssertEqual(m.rows(needsGlobe: false).count, 5)
        XCTAssertEqual(Array(m.rows(needsGlobe: false).dropLast()),
                       KeyboardLayout.letterRows(style: .fourRow))
    }

    // Presentation of the palochka (BASELINE.md §8, finding 3): stored rows
    // are canonical "ӏ" (U+04CF); predictive candidates and the
    // saved-words list show "Ӏ" (U+04C0); the quoted literal keeps the
    // typed form.

    func testSavedWordsShowTheVisiblePalochka() {
        let m = model(learnedWords: ["цӏияб", "гьабуна"])
        XCTAssertEqual(Set(m.savedWords()), ["цӀияб", "гьабуна"])
    }

    func testPredictiveCandidatesShowTheVisiblePalochkaTheLiteralKeepsTheTypedForm() {
        let m = model(learnedWords: ["цӏияб"])
        m.shiftState = .off
        let proxy = MockTextDocumentProxy(before: "Салам цӏи")
        m.syncComposedWord(proxy: proxy)
        m.updateSuggestions(proxy: proxy)
        XCTAssertEqual(m.suggestions, ["цӏи", "цӀияб"])
    }

    func testThePalochkaDoesNotVoteInTheAllCapsTest() {
        let m = model(learnedWords: ["цӏияб"])
        m.shiftState = .off
        let capitalized = MockTextDocumentProxy(before: "Салам ЦӀи")
        m.syncComposedWord(proxy: capitalized)
        m.updateSuggestions(proxy: capitalized)
        XCTAssertEqual(m.suggestions.last, "ЦӀияб")
        let allCaps = MockTextDocumentProxy(before: "Салам ЦӀИ")
        m.syncComposedWord(proxy: allCaps)
        m.updateSuggestions(proxy: allCaps)
        XCTAssertEqual(m.suggestions.last, "ЦӀИЯБ")
    }
}

// MARK: - Language and product constants

final class LanguageConstantsCharacterizationTests: GKTestCase {

    func testAppGroupIdentifier() {
        XCTAssertEqual(KeyboardDefinition.current.data.appGroupID, "group.org.lekitech.generalkeyboard")
    }

    func testNormalizationConstants() {
        XCTAssertEqual(Normalization.version, 1)
        XCTAssertEqual(Normalization.palochka, "\u{04CF}")
        XCTAssertEqual(Normalization.digraphTails, ["\u{04CF}", "\u{044C}", "\u{044A}"])
    }

    func testEveryPalochkaLookalikeIsRepairedInsideCyrillicTokens() {
        for lookalike in ["I", "l", "i", "\u{0406}", "\u{0456}", "\u{04C0}"] {
            XCTAssertEqual(Normalization.canonical("д\(lookalike)д"), "д\u{04CF}д", lookalike)
        }
        for nonLookalike in ["1", "|", "!"] {
            XCTAssertEqual(Normalization.canonical("д\(nonLookalike)д"), "д\(nonLookalike)д")
        }
    }

    func testEveryLatinHomoglyphIsRepairedInsideCyrillicTokens() {
        let pairs: [(String, String)] = [
            ("a", "а"), ("c", "с"), ("e", "е"), ("o", "о"), ("p", "р"), ("x", "х"),
            ("y", "у"), ("k", "к"), ("m", "м"), ("t", "т"), ("b", "ь"), ("h", "н"),
        ]
        for (latin, cyrillic) in pairs {
            XCTAssertEqual(Normalization.canonical("д\(latin)д"), "д\(cyrillic)д", latin)
        }
        XCTAssertEqual(Normalization.canonical("dad"), "dad", "Latin-only tokens stay Latin")
    }

    func testServiceKeyLabels() {
        let expected: [(KeyCap, String, String)] = [
            (.shift, "⇧", "⇧"), (.backspace, "⌫", "⌫"), (.numbers, "123", "123"),
            (.symbols, "#+=", "#+="), (.letters, "аиу", "АИУ"), (.globe, "🌐", "🌐"),
            (.emoji, "😀", "😀"), (.settings, "", ""), (.spacer(0.25), "", ""),
            (.space, "Гьоркьобак\u{04CF}", "Гьоркьобак\u{04CF}"), (.return, "", ""),
        ]
        for (cap, plain, shifted) in expected {
            XCTAssertEqual(KeyboardLayout.label(for: cap, shifted: false), plain, "\(cap)")
            XCTAssertEqual(KeyboardLayout.label(for: cap, shifted: true, capsLock: false),
                           shifted, "\(cap)")
        }
    }

    func testKeyWeightsAndFontSizes() {
        let weights: [(KeyCap, CGFloat)] = [
            (.character("а"), 1.0), (.shift, 1.0), (.backspace, 1.0), (.settings, 1.2),
            (.globe, 1.2), (.emoji, 1.2), (.numbers, 1.2), (.symbols, 1.2), (.letters, 1.2),
            (.return, 1.8), (.space, 4.5), (.spacer(0.25), 0.25),
        ]
        for (cap, w) in weights { XCTAssertEqual(KeyboardLayout.weight(cap), w, "\(cap)") }
        let sizes: [(KeyCap, CGFloat)] = [
            (.character("а"), 22), (.shift, 20), (.backspace, 20), (.globe, 20), (.emoji, 20),
            (.settings, 20), (.space, 13), (.return, 13), (.numbers, 18), (.symbols, 18),
            (.letters, 18), (.spacer(1), 0),
        ]
        for (cap, s) in sizes { XCTAssertEqual(KeyboardLayout.fontSize(for: cap), s, "\(cap)") }
        // Lowercase 24.8 pt: the native x-height (visual refinement 2026-10)
        XCTAssertEqual(KeyboardLayout.fontSize(for: .character("а"), label: "а"), 24.8,
                       accuracy: 0.0001)
        XCTAssertEqual(KeyboardLayout.fontSize(for: .character("а"), label: "А"), 22)
        XCTAssertEqual(KeyboardLayout.fontSize(for: .character("кӏ"), label: "кӏ"),
                       22 * 0.8, accuracy: 0.0001)
    }

    func testReturnKeyWidths() {
        let expected: [(UIReturnKeyType, CGFloat)] = [
            (.default, 1.8), (.go, 2.3), (.send, 2.3), (.done, 2.3), (.next, 2.3),
            (.continue, 2.3), (.join, 2.3), (.route, 1.8), (.search, 1.8),
            (.emergencyCall, 1.8), (.google, 1.8), (.yahoo, 1.8),
        ]
        for (type, w) in expected {
            XCTAssertEqual(KeyboardLayout.returnKeyWeight(for: type), w, "\(type.rawValue)")
        }
        XCTAssertEqual(KeyboardLayout.returnLabel(for: .google), "")
        XCTAssertEqual(KeyboardLayout.returnLabel(for: .yahoo), "")
    }

    /// Titles, SF Symbols, sizes and a digest of every emoji, per category,
    /// in catalog order — regenerating EmojiData must reproduce all of it.
    func testEmojiCatalog() {
        let expected: [(String, String, Int, String)] = [
        ("Гьурмал ва гӀадамал", "face.smiling", 553, "3ab0d2fcee1bd3915654c767a4f3d96ed0bc073870739fd5da28e678ba15b2c4"),
        ("ТӀабигӀат", "pawprint", 158, "771ef102af77b43c46fd21fb0a0b0c5840be2b9db5a487dd9fcaa6953024afd5"),
        ("Квен", "fork.knife", 130, "99f567806b6a7272f62bfc3339d0f9418d8d120375eccc9209d3dad81e9e232a"),
        ("ХӀаял", "soccerball", 85, "8cbfe7144ee4793fa85af41fb1268554eb841de64c0fd5900506ef3fb39584d4"),
        ("Сапар", "car", 218, "89fa5a75f2283ba52e62a3d455f6f9baef7a0e5b49ed2b5fd827645f5b1efee5"),
        ("Жал", "lightbulb", 262, "b231c39219be131f5587b2bbc4cb90a5e0a9ae7c959de08ca18ccb28022faafe"),
        ("ГӀаламатал", "heart", 223, "5af552282df3a5cf75c46eba6a04bf4c098126849839a8579c169e4dcc24d348"),
        ("Байрахъал", "flag", 269, "3942223941b27d861ff98afc86ce996ccf9bc0e9e26b023b849480c9ebd5f836"),
        ]
        XCTAssertEqual(EmojiData.categories.count, expected.count)
        for (category, (title, icon, count, digest)) in zip(EmojiData.categories, expected) {
            // Phase 1b: titles come from the definition, keyed by category id.
            XCTAssertEqual(KeyboardDefinition.current.emojiCategoryTitles[category.id], title)
            XCTAssertEqual(category.icon, icon, title)
            XCTAssertEqual(category.emojis.count, count, title)
            let joined = category.emojis.joined(separator: "\u{1F}")
            let hex = SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hex, digest, title)
        }
    }
}
