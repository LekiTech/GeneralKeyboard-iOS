//
//  LayoutStyleTests.swift
//  GeneralKeyboardTests
//
//  The reference keyboard's two layouts (the Avar fixture data) against
//  their specification, read through the engine's KeyboardLayout facade.
//  The 3-row and 4-row grids are defined independently — these tests pin
//  every row, every callout map, the shift layers, the symbol pages, and
//  the key names EXACTLY, so the layouts cannot drift without a failing
//  test. The engine stays style-blind: its digraph-tail source is the
//  union callout map, asserted unchanged here.
//

import XCTest
@testable import GeneralKeyboard
@testable import GeneralKeyboardBridge
import GeneralKeyboardReference

final class LayoutStyleTests: GKTestCase {

    private func chars(_ row: [KeyCap]) -> [String] {
        row.compactMap { if case .character(let s) = $0 { return s } else { return nil } }
    }

    // MARK: - Default layers (exact)

    func testThreeRowLayoutMatchesTheSpecificationExactly() {
        let rows = KeyboardLayout.letterRows(style: .threeRow)
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(chars(rows[0]), ["й","ц","у","к","е","н","г","ш","щ","з","х","ъ"])
        XCTAssertEqual(chars(rows[1]), ["ф","Ӏ","в","а","п","р","о","л","д","ж","э"])
        XCTAssertEqual(chars(rows[2]), ["я","ч","с","м","и","т","ь","б","ю"])
        XCTAssertEqual(rows[2].first, .shift)
        XCTAssertEqual(rows[2].last, .backspace)
        // The standalone palochka key is the visible palochka Ӏ (U+04C0).
        XCTAssertEqual(chars(rows[1])[1].unicodeScalars.first?.value, 0x4C0)
    }

    func testFourRowLayoutMatchesTheSpecificationExactly() {
        let rows = KeyboardLayout.letterRows(style: .fourRow)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(chars(rows[0]), ["гъ","хъ","къ","кӀ","тӀ","цӀ","чӀ","хӀ","гӀ","кь","хь"])
        XCTAssertEqual(chars(rows[1]), ["й","ц","у","к","е","н","г","ш","щ","з","х"])
        XCTAssertEqual(chars(rows[2]), ["ф","лъ","в","а","п","р","о","л","д","ж","э"])
        XCTAssertEqual(chars(rows[3]), ["я","ч","с","м","и","т","гь","б","ю"])
        XCTAssertEqual(rows[3].first, .shift)
        XCTAssertEqual(rows[3].last, .backspace)
        // Digraph palochkas are the visible palochka Ӏ (U+04C0), never the
        // lookup key ӏ (U+04CF).
        for key in chars(rows[0]) where key.contains("\u{04CF}") {
            XCTFail("digraph \(key) must use the visible palochka Ӏ U+04C0")
        }
    }

    // MARK: - Shift layers (exact, via applyCase)

    func testShiftLayersMatchTheSpecification() {
        // The spec's SHIFT grids capitalize only the first letter of each
        // key: гь → Гь, кӀ → КӀ, лъ → Лъ — applyCase(capsLock: false) is
        // the single function that produces both the label and the
        // inserted text, so asserting it covers both.
        func shifted(_ row: [KeyCap]) -> [String] {
            chars(row).map { KeyboardLayout.applyCase($0, capsLock: false) }
        }
        let three = KeyboardLayout.letterRows(style: .threeRow)
        XCTAssertEqual(shifted(three[0]), ["Й","Ц","У","К","Е","Н","Г","Ш","Щ","З","Х","Ъ"])
        XCTAssertEqual(shifted(three[1]), ["Ф","Ӏ","В","А","П","Р","О","Л","Д","Ж","Э"])
        XCTAssertEqual(shifted(three[2]), ["Я","Ч","С","М","И","Т","Ь","Б","Ю"])

        let four = KeyboardLayout.letterRows(style: .fourRow)
        XCTAssertEqual(shifted(four[0]), ["Гъ","Хъ","Къ","КӀ","ТӀ","ЦӀ","ЧӀ","ХӀ","ГӀ","Кь","Хь"])
        XCTAssertEqual(shifted(four[2]), ["Ф","Лъ","В","А","П","Р","О","Л","Д","Ж","Э"])
        XCTAssertEqual(shifted(four[3]), ["Я","Ч","С","М","И","Т","Гь","Б","Ю"])
    }

    func testEveryVisibleKeyInsertsExactlyWhatItShows() {
        // Unshifted label == inserted text == the key's own string; the
        // shifted label and shifted insertion both come from applyCase.
        for style in LayoutStyle.allCases {
            for row in KeyboardLayout.letterRows(style: style) {
                for key in chars(row) {
                    XCTAssertEqual(
                        KeyboardLayout.label(for: .character(key), shifted: false), key)
                    XCTAssertEqual(
                        KeyboardLayout.label(for: .character(key), shifted: true, capsLock: false),
                        KeyboardLayout.applyCase(key, capsLock: false))
                }
            }
        }
    }

    // MARK: - Symbol layers (exact)

    private let punctuationRow: [KeyCap] =
        [.symbols, .spacer(0.25),
         .character("."), .character(","), .character("?"),
         .character("!"), .character("'"),
         .spacer(0.25), .backspace]
    private let punctuationRowSymbols: [KeyCap] =
        [.numbers, .spacer(0.25),
         .character("."), .character(","), .character("?"),
         .character("!"), .character("'"),
         .spacer(0.25), .backspace]

    func testThreeRowSymbolPagesAreUnchanged() {
        let numbers = KeyboardLayout.numberRows(style: .threeRow)
        XCTAssertEqual(numbers.count, 3)
        XCTAssertEqual(chars(numbers[0]), ["1","2","3","4","5","6","7","8","9","0"])
        XCTAssertEqual(chars(numbers[1]), ["-","/",":",";","(",")","₽","&","@","\""])
        XCTAssertEqual(numbers[2], punctuationRow)

        let symbols = KeyboardLayout.symbolRows(style: .threeRow)
        XCTAssertEqual(symbols.count, 3)
        XCTAssertEqual(chars(symbols[0]), ["[","]","{","}","#","%","^","*","+","="])
        XCTAssertEqual(chars(symbols[1]), ["_","\\","|","~","<",">","$","€","¥","•"])
        XCTAssertEqual(symbols[2], punctuationRowSymbols)
    }

    func testFourRowSymbolPagesMatchTheApprovedProposal() {
        let numbers = KeyboardLayout.numberRows(style: .fourRow)
        XCTAssertEqual(numbers.count, 4)
        XCTAssertEqual(chars(numbers[0]), ["1","2","3","4","5","6","7","8","9","0"])
        XCTAssertEqual(chars(numbers[1]), ["-","/",":",";","(",")","₽","&","@","\""])
        XCTAssertEqual(chars(numbers[2]), ["$","€","£","¥","￦","°","№","«","»","…"])
        XCTAssertEqual(numbers[3], punctuationRow)

        let symbols = KeyboardLayout.symbolRows(style: .fourRow)
        XCTAssertEqual(symbols.count, 4)
        XCTAssertEqual(chars(symbols[0]), ["[","]","{","}","#","%","^","*","+","="])
        XCTAssertEqual(chars(symbols[1]), ["_","\\","|","~","<",">","•","–","—","§"])
        XCTAssertEqual(chars(symbols[2]), ["≠","≈","‰","∞","¿","¡","’","„","“","”"])
        XCTAssertEqual(symbols[3], punctuationRowSymbols)
    }

    func testLetterAndSymbolPagesHaveIdenticalRowCountsPerStyle() {
        // The geometry-stability contract: switching ABC ↔ 123 never moves
        // the keyboard content vertically, because every page of a style
        // has the same number of rows inside the same total height.
        for style in LayoutStyle.allCases {
            let letters = KeyboardLayout.letterRows(style: style).count
            XCTAssertEqual(KeyboardLayout.numberRows(style: style).count, letters)
            XCTAssertEqual(KeyboardLayout.symbolRows(style: style).count, letters)
        }
    }

    // MARK: - Long-press maps (exact, per style)

    private let expectedShared: [String: [String]] = [
        "ц": ["цӀ"],
        "к": ["кӀ", "къ", "кь"],
        "г": ["гӀ", "гъ", "гь"],
        "х": ["хӀ", "хъ", "хь"],
        "л": ["лъ", "лӀ"],
        "ч": ["чӀ"],
        "т": ["тӀ"],
        "а": ["а\u{0301}"],
        "е": ["ё", "е\u{0301}"],
        "и": ["ы", "и\u{0301}"],
        "о": ["о\u{0301}"],
        "у": ["у\u{0301}"],
        "э": ["э\u{0301}"],
        "я": ["я\u{0301}"],
        "ю": ["ю\u{0301}"],
        "0": ["°"],
        "₽": ["$", "€", "£", "¥", "￦"],
        "#": ["№"],
        ".": ["…"],
        "%": ["‰", "∞"],
        "=": ["≠", "≈"],
        "-": ["•", "–", "—"],
        "&": ["§"],
        "?": ["¿"],
        "!": ["¡"],
        "'": ["’", "‘", "`"],
        "\"": ["”", "“", "„", "»", "«"],
    ]

    func testThreeRowCalloutsMatchTheSpecification() {
        XCTAssertEqual(KeyboardLayout.callouts(style: .threeRow),
                       expectedShared.merging(["Ӏ": ["ы"]]) { c, _ in c })
    }

    func testFourRowCalloutsMatchTheSpecification() {
        XCTAssertEqual(KeyboardLayout.callouts(style: .fourRow),
                       expectedShared.merging([
                           "гь": ["ь", "ъ"],
                           "гъ": ["ъ"],
                           "кӀ": ["Ӏ"],
                           "лъ": ["лӀ", "ы"],
                       ]) { c, _ in c })
        // The slash deliberately has no alternatives, in either style.
        for style in LayoutStyle.allCases {
            XCTAssertNil(KeyboardLayout.callouts(style: style)["/"])
        }
    }

    func testUppercaseCalloutVariantsDeriveMechanically() {
        // The spec's uppercase rows (А: А́, Лъ: ЛӀ Ы, Гь: Ь Ъ) come from
        // the same lowercase entries: the bubble and the insertion both
        // run the selected option through applyCase.
        func shifted(_ options: [String]) -> [String] {
            options.map { KeyboardLayout.applyCase($0, capsLock: false) }
        }
        let four = KeyboardLayout.callouts(style: .fourRow)
        XCTAssertEqual(shifted(four["лъ"]!), ["ЛӀ", "Ы"])
        XCTAssertEqual(shifted(four["гь"]!), ["Ь", "Ъ"])
        XCTAssertEqual(shifted(four["а"]!), ["А\u{0301}"])
        XCTAssertEqual(shifted(KeyboardLayout.callouts(style: .threeRow)["Ӏ"]!), ["Ы"])
    }

    // MARK: - Reachability

    private func typeable(style: LayoutStyle) -> Set<String> {
        var result = Set<String>()
        for row in KeyboardLayout.letterRows(style: style) {
            result.formUnion(chars(row))
        }
        result.formUnion(KeyboardLayout.callouts(style: style).values.flatMap { $0 })
        return result
    }

    func testEveryAvarCharacterIsTypeableInBothStyles() {
        let required: Set<String> = [
            "ъ", "ь", "Ӏ", "ы", "ё", "ф", "щ",
            "гъ", "хъ", "къ", "кӀ", "тӀ", "цӀ", "чӀ", "хӀ", "гӀ", "кь", "хь",
            "гь", "лъ", "лӀ",
        ]
        for style in LayoutStyle.allCases {
            let set = typeable(style: style)
            for token in required {
                XCTAssertTrue(set.contains(token),
                              "\(token) must stay typeable in \(style)")
            }
        }
    }

    func testEverySymbolIsReachableInBothStyles() {
        // Union of visible symbol keys and their long-press alternates.
        func reachable(style: LayoutStyle) -> Set<String> {
            var set = Set<String>()
            for rows in [KeyboardLayout.numberRows(style: style),
                         KeyboardLayout.symbolRows(style: style)] {
                for row in rows { set.formUnion(chars(row)) }
            }
            set.formUnion(KeyboardLayout.callouts(style: style).values.flatMap { $0 })
            return set
        }
        let inventory: Set<String> = [
            "$", "€", "£", "¥", "￦", "°", "№", "«", "»", "…",
            "•", "–", "—", "§", "≠", "≈", "‰", "∞", "¿", "¡",
            "’", "‘", "`", "„", "“", "”", "₽",
        ]
        for style in LayoutStyle.allCases {
            let set = reachable(style: style)
            for symbol in inventory {
                XCTAssertTrue(set.contains(symbol),
                              "\(symbol) must stay reachable in \(style)")
            }
        }
    }

    // MARK: - Engine neutrality

    func testEngineTailSourceIsTheStyleBlindUnion() {
        // Normalization and the learned store derive digraph tails from
        // the union map — asserting the derived set proves the layout
        // rework cannot have moved the engine.
        // Tails are lookup-key characters: the canonical palochka ӏ U+04CF.
        XCTAssertEqual(Normalization.digraphTails, Set("ӏъь"))
        for (key, alternates) in KeyboardLayout.callouts(style: .fourRow) {
            XCTAssertEqual(KeyboardLayout.callouts[key], alternates,
                           "union map must contain every style's entries")
        }
    }

    // MARK: - Key names (exact, per the spec's table)

    func testKeyNamesMatchTheSpecification() {
        XCTAssertEqual(KeyboardLayout.label(for: .space, shifted: false), "ГьоркьобакӀ")
        XCTAssertEqual(KeyboardLayout.label(for: .return, shifted: false), "",
                       "empty label — the view draws the ⏎ symbol")
        XCTAssertEqual(KeyboardLayout.label(for: .letters, shifted: false), "аиу")
        XCTAssertEqual(KeyboardLayout.label(for: .letters, shifted: true), "АИУ")

        XCTAssertEqual(KeyboardLayout.returnLabel(for: .default), "",
                       "plain return shows the ⏎ symbol, not a word")
        XCTAssertEqual(KeyboardLayout.returnLabel(for: .go), "Рагьизе")
        XCTAssertEqual(KeyboardLayout.returnLabel(for: .send), "БитӀизе")
        XCTAssertEqual(KeyboardLayout.returnLabel(for: .done), "ЛъугӀана")
        XCTAssertEqual(KeyboardLayout.returnLabel(for: .next), "Хадусеб")
        XCTAssertEqual(KeyboardLayout.returnLabel(for: .continue), "Цебехун")
        XCTAssertEqual(KeyboardLayout.returnLabel(for: .join), "Цолъизе")
        XCTAssertEqual(KeyboardLayout.returnLabel(for: .route), "Нух")
        XCTAssertEqual(KeyboardLayout.returnLabel(for: .search), "Хъирщи")
        XCTAssertEqual(KeyboardLayout.returnLabel(for: .emergencyCall), "SOS")
    }

    // MARK: - Geometry and persistence contracts

    func testGeometryStaysFrozen() {
        XCTAssertEqual(KeyboardLayout.metrics(for: .threeRow),
                       KeyboardLayout.Metrics(totalHeight: 250, keyHeight: 43, rowSpacing: 11,
                                              emojiRows: 5, emojiCellHeight: 33))
        XCTAssertEqual(KeyboardLayout.metrics(for: .fourRow),
                       KeyboardLayout.Metrics(totalHeight: 304, keyHeight: 43, rowSpacing: 11,
                                              emojiRows: 6, emojiCellHeight: 36))
    }

    func testEmojiGridFillsEachStyleWithoutOverflow() {
        // Emoji page vertical budget: 8 top pad + ~16 title + 4 pad +
        // grid + 36 category bar ≤ totalHeight, with the leftover slack
        // small and comparable across styles (no floating grid).
        for style in LayoutStyle.allCases {
            let m = KeyboardLayout.metrics(for: style)
            let grid = CGFloat(m.emojiRows) * m.emojiCellHeight
                     + CGFloat(m.emojiRows - 1) * 2
            let slack = m.totalHeight - (8 + 16 + 4 + grid + 36)
            XCTAssertGreaterThanOrEqual(slack, 0,
                "emoji grid must not overflow the \(style) keyboard")
            XCTAssertLessThanOrEqual(slack, 20,
                "emoji grid must fill the \(style) keyboard, not float")
        }
    }

    func testLayoutStyleRawValuesAreStable() {
        XCTAssertEqual(LayoutStyle.threeRow.rawValue, "threeRow")
        XCTAssertEqual(LayoutStyle.fourRow.rawValue, "fourRow")
    }
}
