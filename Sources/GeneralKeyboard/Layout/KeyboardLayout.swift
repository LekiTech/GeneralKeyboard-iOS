//
//  KeyboardLayout.swift
//  GeneralKeyboard
//
//  Created by Enver Eskendarov on 6/28/26.
//
//  Engine side of the layout: key types, geometry types, case rules, label
//  resolution, widths and fonts. The language's rows, callouts, per-style
//  metrics and key names come from `KeyboardDefinition.current`
//  read here through the static accessors below.
//

import SwiftUI

/// What a key does when tapped.
/// `.character(s)` inserts `s` exactly as the layout defines it (lowercase;
/// shift applies at insertion through applyCase). Storage normalizes every
/// token through the keyboard's NormalizationProfile.
public enum KeyCap: Equatable, Sendable {
    case character(String)
    case shift
    case backspace
    case numbers    // switch to "123" page
    case symbols    // switch to "#+=" page
    case letters    // switch back to alphabet
    case globe      // input mode switch (required for App Store)
    case emoji      // emoji page (Step 4)
    case settings   // opens the in-keyboard settings panel
    case space
    case `return`
    /// Invisible, non-interactive gap of the given width weight —
    /// used by the symbol rows to center the punctuation cluster.
    case spacer(CGFloat)
}

enum KeyboardPage {
    case letters, numbers, symbols, emoji
}

public enum KeyboardLayout {

    private static var layout: LayoutCapabilities { KeyboardDefinition.current.layout }
    private static var keys: KeyLabels { KeyboardDefinition.current.keys }

    // MARK: - Pages and long-press maps of the current keyboard, per style

    static func letterRows(style: LayoutStyle) -> [[KeyCap]] {
        layout.spec(for: style).letterRows
    }

    static func numberRows(style: LayoutStyle) -> [[KeyCap]] {
        layout.spec(for: style).numberRows
    }

    static func symbolRows(style: LayoutStyle) -> [[KeyCap]] {
        layout.spec(for: style).symbolRows
    }

    /// Alternates are inserted as a whole string; the popup auto-prepends
    /// the base key, so alternates never repeat it. Uppercase variants are
    /// derived mechanically through applyCase.
    static func callouts(style: LayoutStyle) -> [String: [String]] {
        layout.spec(for: style).callouts
    }

    /// Union of every style's map — the style-blind view the definition
    /// tests check the normalization profile's digraph tails against.
    /// Never used for rendering.
    static let callouts: [String: [String]] = KeyboardDefinition.current.layout.calloutUnion

    // MARK: - Vertical geometry per style

    /// The vertical numbers the keyboard is built from; each style of the
    /// definition carries its own.
    public struct Metrics: Equatable, Sendable {
        public let totalHeight: CGFloat
        public let keyHeight: CGFloat
        public let rowSpacing: CGFloat
        /// Emoji page grid: emojis per column and the cell height. The
        /// taller 4-row keyboard fits one more emoji per column in
        /// slightly taller cells, so the grid fills the same content area
        /// as the letter/symbol pages and the category bar stays put.
        public let emojiRows: Int
        public let emojiCellHeight: CGFloat

        public init(totalHeight: CGFloat, keyHeight: CGFloat, rowSpacing: CGFloat, emojiRows: Int, emojiCellHeight: CGFloat) {
            self.totalHeight = totalHeight
            self.keyHeight = keyHeight
            self.rowSpacing = rowSpacing
            self.emojiRows = emojiRows
            self.emojiCellHeight = emojiCellHeight
        }
    }

    static func metrics(for style: LayoutStyle) -> Metrics {
        layout.spec(for: style).metrics
    }

    // MARK: - Case helpers

    /// Capitalizes only the first character — correct for digraphs: "къ" → "Къ", "лъ" → "Лъ".
    static func capitalizedFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        return String(f).uppercased() + s.dropFirst()
    }

    /// Applies shift state to a string. Use instead of .uppercased().
    /// - capsLock true  → fully uppercase ("къ" → "КЪ")
    /// - capsLock false → first letter only ("къ" → "Къ")
    static func applyCase(_ s: String, capsLock: Bool) -> String {
        capsLock ? s.uppercased() : capitalizedFirst(s)
    }

    // MARK: - Key labels

    static func label(for cap: KeyCap, shifted: Bool, capsLock: Bool = true) -> String {
        switch cap {
        // applyCase keeps digraph keys honest under shift-once: «гъ»
        // previews as «Гъ», not «ГЪ» — exactly what a tap will insert.
        // Single letters are unaffected (first-letter == whole label).
        case .character(let s): return shifted ? applyCase(s, capsLock: capsLock) : s
        case .shift:            return "⇧"
        case .backspace:        return "⌫"
        case .numbers:          return "123"
        case .symbols:          return "#+="
        case .letters:          return shifted ? keys.lettersKeyShifted : keys.lettersKey
        case .globe:            return "🌐"
        case .emoji:            return "😀"
        case .settings:         return ""    // gear icon, rendered by KeyButton
        case .spacer:           return ""
        case .space:            return keys.space
        case .return:           return ""   // ⏎ symbol, drawn by KeyButton
        }
    }

    // MARK: - Key width weight (relative, used as layoutPriority)

    static func weight(_ cap: KeyCap) -> CGFloat {
        switch cap {
        case .character:                    return 1.0
        case .shift, .backspace:            return 1.0
        // The «123» / gear / emoji cluster must be exactly equal-sized
        case .settings, .globe, .emoji,
             .numbers, .symbols, .letters:  return 1.2
        case .return:                       return 1.8
        case .space:                        return 4.5
        case .spacer(let w):                return w
        }
    }

    // MARK: - Return key

    /// Action label for the return key, from the definition. An empty
    /// label means "show an icon" — the plain return key deliberately shows
    /// the ⏎ symbol, not a word.
    static func returnLabel(for type: UIReturnKeyType) -> String {
        keys.returnLabels[type] ?? ""
    }

    /// Return-key width in row units, adapted to its label: icons and
    /// short labels keep the native 1.8, longer labels get more
    /// room so the typography stays readable instead of shrinking. Row
    /// weights normalize against their total, so the space bar absorbs
    /// the difference and the layout stays balanced.
    static func returnKeyWeight(for type: UIReturnKeyType) -> CGFloat {
        returnLabel(for: type).count <= 6 ? 1.8 : 2.3
    }

    // MARK: - Label font size

    static func fontSize(for cap: KeyCap) -> CGFloat {
        switch cap {
        case .character:                   return 22
        case .shift, .backspace,
             .globe, .emoji, .settings:    return 20
        case .space:                       return 13
        case .return:                      return 13
        case .numbers, .symbols, .letters: return 18
        case .spacer:                      return 0
        }
    }

    /// Size for the label actually rendered on the key. Lowercase letters
    /// are optically much smaller than caps at the same point size (x-height
    /// vs cap height), so they are set larger: 24.8 pt gives the native
    /// keyboard's 12.7 pt x-height, while uppercase at 22 pt already has its
    /// 15.3 pt cap height (measured on the iOS 27 Russian keyboard, iPhone
    /// 18 Pro). Digits and punctuation have no case and keep the base size.
    static func fontSize(for cap: KeyCap, label: String) -> CGFloat {
        let base = fontSize(for: cap)
        // Digraph keys draw two glyphs in a single-key width; the lowercase
        // bump would overflow the cap, so they step down instead.
        if case .character = cap, label.count > 1 {
            return base * 0.8
        }
        if case .character = cap, label != label.uppercased() {
            return lowercaseCharacterSize
        }
        return base
    }

    static let lowercaseCharacterSize: CGFloat = 24.8

    /// Character keys use the plain system font, regular weight and
    /// standard width, like the native keyboard: measured glyph widths match
    /// native within 1% and stroke weight within ~7% (an earlier on-device
    /// tuning used medium-ish weight 0.19 and a condensed width, which drew
    /// letters ~20% heavier and ~10% narrower than native).
    static func keyLabelFont(for cap: KeyCap, label: String) -> Font {
        .system(size: fontSize(for: cap, label: label))
    }

    /// The key preview card's letter: the key-label face at the size the
    /// card asks for (native: ~36 pt for upper- and lowercase alike);
    /// digraphs step down like on the keys.
    static func previewFont(label: String, size base: CGFloat) -> Font {
        .system(size: label.count > 1 ? base * 0.8 : base)
    }

    /// The native keyboard puts every character key's label on one
    /// baseline, ~28 pt below the top of a 43 pt key (6.5 pt below its
    /// center) — lowercase and uppercase alike, so lowercase letters sit
    /// visually centered and capitals slightly above center. SwiftUI centers
    /// the text's line box instead; this is the vertical shift that moves the
    /// baseline to the native position.
    static let nativeBaselineBelowCenter: CGFloat = 6.5

    static func labelBaselineShift(for cap: KeyCap, label: String) -> CGFloat {
        guard case .character = cap else { return 0 }
        let font = UIFont.systemFont(ofSize: fontSize(for: cap, label: label))
        // A centered line box puts the baseline (ascender + descender) / 2
        // below center (descender is negative).
        let centeredBaseline = (font.ascender + font.descender) / 2
        return nativeBaselineBelowCenter - centeredBaseline
    }
}
