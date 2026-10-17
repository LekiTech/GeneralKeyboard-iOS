//
//  ReferenceLayout.swift
//  GeneralKeyboardReference
//
//  The reference keyboard's layouts. Fixture data: the Avar keyboard's two
//  styles copied verbatim from AvarKeyboard-iOS@d249496 (approved design
//  decision 8), so the engine can be exercised end to end — and its
//  rendering compared pixel for pixel with Avar's — without depending on
//  any product code. Never linked by a shipping keyboard.
//

import Foundation
import GeneralKeyboard

enum ReferenceLayout {

    static let capabilities = LayoutCapabilities(
        styles: [threeRow, fourRow],
        defaultStyle: .threeRow,
        showsStyleSelector: true,
        persistenceKey: "layoutStyle",
        // Every engine capability on: a long press on the gear opens the
        // quick layout menu
        quickSwitchOnSettingsLongPress: true
    )

    /// `.threeRow` is the original layout and its geometry is frozen.
    static let threeRow = LayoutStyleSpec(
        id: .threeRow,
        letterRows: threeRowRows,
        numberRows: threeRowNumberRows,
        symbolRows: threeRowSymbolRows,
        callouts: threeRowCallouts,
        metrics: KeyboardLayout.Metrics(totalHeight: 250, keyHeight: 43, rowSpacing: 11,
                                        emojiRows: 5, emojiCellHeight: 33),
        settingsTitle: "3 мухъ",
        settingsSubtitle: String(localized: "three letter rows", bundle: .module)
    )

    /// `.fourRow` keeps the SAME key height and row gap — the familiar rows
    /// are not compressed — and pays for its extra row in keyboard height:
    /// 36 bar + 8 gap + 5×43 keys + 4×11 gaps + 1 pt slack = 304. The emoji
    /// grid gains one emoji per column in slightly taller cells.
    static let fourRow = LayoutStyleSpec(
        id: .fourRow,
        letterRows: fourRowRows,
        numberRows: fourRowNumberRows,
        symbolRows: fourRowSymbolRows,
        callouts: fourRowCallouts,
        metrics: KeyboardLayout.Metrics(totalHeight: 304, keyHeight: 43, rowSpacing: 11,
                                        emojiRows: 6, emojiCellHeight: 36),
        settingsTitle: "4 мухъ",
        settingsSubtitle: String(localized: "four rows — digraphs on top", bundle: .module)
    )

    // MARK: - Letter rows (fixed Avar layouts, defined independently)
    //
    // ↓↓↓  ADD OR REORDER KEYS HERE ONLY  ↓↓↓
    private static let threeRowRows: [[KeyCap]] = [
        ["й","ц","у","к","е","н","г","ш","щ","з","х","ъ"].map { .character($0) },  // 12 keys
        ["ф","Ӏ","в","а","п","р","о","л","д","ж","э"].map { .character($0) },      // 11 keys
        [.shift]
            + ["я","ч","с","м","и","т","ь","б","ю"].map { KeyCap.character($0) }
            + [.backspace],
    ]

    private static let fourRowRows: [[KeyCap]] = [
        ["гъ","хъ","къ","кӀ","тӀ","цӀ","чӀ","хӀ","гӀ","кь","хь"].map { .character($0) },  // 11 keys
        ["й","ц","у","к","е","н","г","ш","щ","з","х"].map { .character($0) },              // 11 keys
        ["ф","лъ","в","а","п","р","о","л","д","ж","э"].map { .character($0) },             // 11 keys
        [.shift]
            + ["я","ч","с","м","и","т","гь","б","ю"].map { KeyCap.character($0) }
            + [.backspace],
    ]
    // ↑↑↑  -----------------------------------  ↑↑↑

    // MARK: - Number and symbol pages, per style

    private static let punctuationRow: [KeyCap] =
        [.symbols, .spacer(0.25)]
            + [".",",","?","!","'"].map { KeyCap.character($0) }
            + [.spacer(0.25), .backspace]

    private static let punctuationRowSymbols: [KeyCap] =
        [.numbers, .spacer(0.25)]
            + [".",",","?","!","'"].map { KeyCap.character($0) }
            + [.spacer(0.25), .backspace]

    private static let threeRowNumberRows: [[KeyCap]] = [
        ["1","2","3","4","5","6","7","8","9","0"].map { .character($0) },
        ["-","/",":",";","(",")","₽","&","@","\""].map { .character($0) },
        punctuationRow,
    ]

    private static let fourRowNumberRows: [[KeyCap]] = [
        ["1","2","3","4","5","6","7","8","9","0"].map { .character($0) },
        ["-","/",":",";","(",")","₽","&","@","\""].map { .character($0) },
        ["$","€","£","¥","￦","°","№","«","»","…"].map { .character($0) },
        punctuationRow,
    ]

    private static let threeRowSymbolRows: [[KeyCap]] = [
        ["[","]","{","}","#","%","^","*","+","="].map { .character($0) },
        ["_","\\","|","~","<",">","$","€","¥","•"].map { .character($0) },
        punctuationRowSymbols,
    ]

    private static let fourRowSymbolRows: [[KeyCap]] = [
        ["[","]","{","}","#","%","^","*","+","="].map { .character($0) },
        ["_","\\","|","~","<",">","•","–","—","§"].map { .character($0) },
        ["≠","≈","‰","∞","¿","¡","’","„","“","”"].map { .character($0) },
        punctuationRowSymbols,
    ]

    // MARK: - Long-press callouts, per style
    //
    // These maps reproduce the ava-3-rows / ava-4-rows long-press
    // specification natively: the shared block is the digraph sets, the
    // accented vowels, and the symbol variants; the 3-row style adds Ӏ→ы
    // (it has a standalone Ӏ key), and the 4-row style adds component access
    // on its digraph keys because standalone ь, ъ and Ӏ have no dedicated
    // keys there. The slash deliberately has no alternatives.
    private static let sharedCallouts: [String: [String]] = [
        // Digraphs on the base letters
        "ц": ["цӀ"],
        "к": ["кӀ", "къ", "кь"],
        "г": ["гӀ", "гъ", "гь"],
        "х": ["хӀ", "хъ", "хь"],
        "л": ["лъ", "лӀ"],
        "ч": ["чӀ"],
        "т": ["тӀ"],
        // Vowels: existing alternates first, stress accent appended
        "а": ["а\u{0301}"],
        "е": ["ё", "е\u{0301}"],
        "и": ["ы", "и\u{0301}"],
        "о": ["о\u{0301}"],
        "у": ["у\u{0301}"],
        "э": ["э\u{0301}"],
        "я": ["я\u{0301}"],
        "ю": ["ю\u{0301}"],
        // Symbols
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

    private static let threeRowCallouts: [String: [String]] =
        sharedCallouts.merging(["Ӏ": ["ы"]]) { current, _ in current }

    private static let fourRowCallouts: [String: [String]] =
        sharedCallouts.merging([
            "гь": ["ь", "ъ"],
            "гъ": ["ъ"],
            "кӀ": ["Ӏ"],
            "лъ": ["лӀ", "ы"],
        ]) { current, _ in current }
}
