//
//  KeyboardDefinition.swift
//  GeneralKeyboard
//
//  The boundary between the General Keyboard engine and one concrete
//  language keyboard. Everything the engine needs to know about a
//  language or a product arrives through a single value of this type:
//  layouts, key labels, native UI strings, the dictionary artifacts, the
//  App Group, the presentation conventions and the normalization profile.
//  Engine files do not spell any of those; the exceptions are deliberate
//  and tested: the built-in normalization profile and one frozen
//  historical migration.
//
//  A product installs its definition once, from its principal class,
//  BEFORE the engine is touched (see GeneralKeyboardViewController):
//
//      final class KeyboardViewController: GeneralKeyboardViewController {
//          override init(nibName: String?, bundle: Bundle?) {
//              KeyboardDefinition.install(MyDefinition.definition)
//              super.init(nibName: nibName, bundle: bundle)
//          }
//          required init?(coder: NSCoder) {
//              KeyboardDefinition.install(MyDefinition.definition)
//              super.init(coder: coder)
//          }
//      }
//
//  Engine statics read the definition on first use and keep it for the
//  life of the process, so it must be installed first and never changed.
//  Installing the same definition again (every new controller does) is a
//  no-op; one with another id after first use is rejected (install(_:)).
//

import UIKit

public struct KeyboardDefinition: Sendable {
    /// Stable identity of this definition, e.g. the extension's bundle
    /// identifier. Installing a definition with the installed `id` again is
    /// a no-op, so every distinct definition needs its own `id`.
    public var id: String
    public var data: LanguageData
    public var layout: LayoutCapabilities
    public var keys: KeyLabels
    public var text: TextConventions
    public var normalization: NormalizationProfile
    public var strings: KeyboardStrings
    /// Native section titles of the emoji catalog, keyed by
    /// `EmojiCatalog.categoryIDs`.
    public var emojiCategoryTitles: [String: String]

    public init(
                id: String,
                data: LanguageData,
                layout: LayoutCapabilities,
                keys: KeyLabels,
                text: TextConventions,
                normalization: NormalizationProfile,
                strings: KeyboardStrings,
                emojiCategoryTitles: [String: String]) {
        self.id = id
        self.data = data
        self.layout = layout
        self.keys = keys
        self.text = text
        self.normalization = normalization
        self.strings = strings
        self.emojiCategoryTitles = emojiCategoryTitles
    }

    /// Structural problems a product definition must not ship with. Checked
    /// by the product's definition tests; never enforced at runtime, so a
    /// definition mistake can never take a running keyboard down.
    public func validationErrors() -> [String] {
        var errors = layout.validationErrors()
        for category in EmojiData.categories where emojiCategoryTitles[category.id] == nil {
            errors.append("no emoji title for category \(category.id)")
        }
        for key in emojiCategoryTitles.keys
        where !EmojiData.categories.contains(where: { $0.id == key }) {
            errors.append("emoji title for unknown category \(key)")
        }
        return errors
    }
}

// MARK: - Data and identity

public struct LanguageData: Sendable {
    /// App Group shared by the container app and the keyboard (contribution bridge).
    public var appGroupID: String
    /// Bundled dictionary: the resource name without `.sqlite`, which is
    /// also the `artifact` value its meta table must carry.
    public var wordsArtifact: String
    /// Bundled static bigrams, same convention.
    public var bigramsArtifact: String
    /// Logger subsystem when `Bundle.main` has no identifier (DEBUG-only diagnostics).
    public var diagnosticsSubsystem: String

    public init(
                appGroupID: String,
                wordsArtifact: String,
                bigramsArtifact: String,
                diagnosticsSubsystem: String) {
        self.appGroupID = appGroupID
        self.wordsArtifact = wordsArtifact
        self.bigramsArtifact = bigramsArtifact
        self.diagnosticsSubsystem = diagnosticsSubsystem
    }
}

/// The running bundle's marketing version, shown in the settings panel. In
/// the keyboard extension `Bundle.main` is the .appex, whose
/// CFBundleShortVersionString is the project's MARKETING_VERSION. Tests
/// assign a fixed value.
enum BundleInfo {
    nonisolated(unsafe) static var marketingVersion: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
}

// MARK: - Layout capabilities

/// Identifier of one letter grid. Open rather than a closed enum: a product
/// names its own styles. The raw value is persisted in UserDefaults, so a
/// shipped style must never be renamed.
public struct LayoutStyle: RawRepresentable, Hashable, CaseIterable, CustomStringConvertible, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    /// Conventional identifiers; any product may define others.
    public static let threeRow = LayoutStyle(rawValue: "threeRow")
    public static let fourRow = LayoutStyle(rawValue: "fourRow")

    /// The styles the current keyboard offers, in settings order.
    public static var allCases: [LayoutStyle] { KeyboardDefinition.current.layout.styles.map(\.id) }
}

/// One complete grid: letter, number and symbol pages, the long-press map,
/// the vertical geometry, and how the style is named in settings.
public struct LayoutStyleSpec: Sendable {
    public var id: LayoutStyle
    public var letterRows: [[KeyCap]]
    public var numberRows: [[KeyCap]]
    public var symbolRows: [[KeyCap]]
    /// Alternates per base key, lowercase keys; the popup prepends the base.
    public var callouts: [String: [String]]
    public var metrics: KeyboardLayout.Metrics
    /// Native title of the style's row in the settings panel.
    public var settingsTitle: String
    /// Explanatory subtitle (already localized).
    public var settingsSubtitle: String
    /// Keys the letters page's bottom row carries right after the space
    /// bar in this style (for example a letter that has no room in the
    /// grid). Empty for most keyboards.
    public var bottomRowAfterSpace: [KeyCap]
    /// The style's row in the quick layout menu (long press on the gear
    /// key); nil uses `settingsTitle` / `settingsSubtitle`.
    public var quickSwitchTitle: String?
    public var quickSwitchSubtitle: String?

    public init(
                id: LayoutStyle,
                letterRows: [[KeyCap]],
                numberRows: [[KeyCap]],
                symbolRows: [[KeyCap]],
                callouts: [String: [String]],
                metrics: KeyboardLayout.Metrics,
                settingsTitle: String,
                settingsSubtitle: String,
                bottomRowAfterSpace: [KeyCap] = [],
                quickSwitchTitle: String? = nil,
                quickSwitchSubtitle: String? = nil) {
        self.id = id
        self.letterRows = letterRows
        self.numberRows = numberRows
        self.symbolRows = symbolRows
        self.callouts = callouts
        self.metrics = metrics
        self.settingsTitle = settingsTitle
        self.settingsSubtitle = settingsSubtitle
        self.bottomRowAfterSpace = bottomRowAfterSpace
        self.quickSwitchTitle = quickSwitchTitle
        self.quickSwitchSubtitle = quickSwitchSubtitle
    }
}

/// How a keyboard sizes and places its keys in iPhone portrait.
public enum KeyboardGridModel: Sendable, Equatable {
    /// Key widths from relative weights, rows inset 6 pt from the edges,
    /// positions left fractional. The geometry shipped before the native
    /// grid existed.
    case weighted
    /// The grid of Apple's iPhone portrait keyboard, measured on iOS 27
    /// (keyboard-geometry/: every one of the native keyboard's 74 key edges
    /// reproduced within 0.2 px). The content width is the keyboard width
    /// less 3.5 pt per side; each row is split into cells (letter rows:
    /// equal cells per row; bottom row: system keys 1/8, return 1/4, space
    /// the rest); each key is its cell less 3 pt per side, and every edge is
    /// rounded to the pixel grid on its own. The suggestion region is sized
    /// so the keyboard's panel lines up with the native one.
    case nativeCells
}

public struct LayoutCapabilities: Sendable {
    /// Every style the keyboard offers, in settings order. Never empty.
    public var styles: [LayoutStyleSpec]
    public var defaultStyle: LayoutStyle
    /// Whether the settings panel lets the user switch. Honored only when
    /// more than one style exists.
    public var showsStyleSelector: Bool
    /// UserDefaults key holding the chosen style's raw value. Part of the
    /// product's persisted contract — never rename.
    public var persistenceKey: String
    /// A long press on the gear key opens a menu of the styles; sliding to
    /// one and releasing switches to it. A tap still opens the settings
    /// panel. Honored only when the selector is shown.
    public var quickSwitchOnSettingsLongPress: Bool
    /// How keys are sized and placed in iPhone portrait (see
    /// `KeyboardGridModel`). Other size classes always use the weighted
    /// layout.
    public var gridModel: KeyboardGridModel

    public init(
                styles: [LayoutStyleSpec],
                defaultStyle: LayoutStyle,
                showsStyleSelector: Bool,
                persistenceKey: String,
                quickSwitchOnSettingsLongPress: Bool = false,
                gridModel: KeyboardGridModel = .weighted) {
        self.styles = styles
        self.defaultStyle = defaultStyle
        self.showsStyleSelector = showsStyleSelector
        self.persistenceKey = persistenceKey
        self.quickSwitchOnSettingsLongPress = quickSwitchOnSettingsLongPress
        self.gridModel = gridModel
    }

    public var showsSelector: Bool { showsStyleSelector && styles.count > 1 }

    /// Whether a long press on the gear key opens the quick layout menu.
    public var showsQuickSwitch: Bool { quickSwitchOnSettingsLongPress && showsSelector }

    /// The persisted raw value if it names an offered style, else the
    /// default. A value is never rewritten until the user picks a style.
    public func resolve(_ raw: String?) -> LayoutStyle {
        guard let raw, let match = styles.first(where: { $0.id.rawValue == raw })
        else { return defaultStyle }
        return match.id
    }

    public func spec(for style: LayoutStyle) -> LayoutStyleSpec {
        styles.first { $0.id == style }
            ?? styles.first { $0.id == defaultStyle }
            ?? styles[0]
    }

    /// Every style's callouts in one map, later styles winning on a shared
    /// key — the style-blind view the definition tests check the digraph
    /// tails against. Never used for rendering.
    public var calloutUnion: [String: [String]] {
        styles.reduce(into: [:]) { union, spec in
            union.merge(spec.callouts) { _, later in later }
        }
    }

    public func validationErrors() -> [String] {
        var errors: [String] = []
        if styles.isEmpty { errors.append("no layout styles") }
        if Set(styles.map(\.id)).count != styles.count { errors.append("duplicate style ids") }
        if !styles.contains(where: { $0.id == defaultStyle }) {
            errors.append("default style \(defaultStyle) is not offered")
        }
        for spec in styles {
            if spec.numberRows.count != spec.symbolRows.count {
                errors.append("\(spec.id): number and symbol pages differ in row count")
            }
            if spec.letterRows.count != spec.numberRows.count {
                errors.append("\(spec.id): letter and number pages differ in row count")
            }
            for key in spec.callouts.keys where key != key.lowercased() {
                errors.append("\(spec.id): callout key \(key) is not lowercase")
            }
            for cap in spec.bottomRowAfterSpace {
                guard case .character = cap else {
                    errors.append("\(spec.id): bottom row keys after space must be characters")
                    continue
                }
            }
        }
        return errors
    }
}

// MARK: - Keys, presentation, strings

public struct KeyLabels: Sendable {
    /// `KeyboardLayout.label(for: .space)`; the bar itself draws `spaceCornerLabel`.
    public var space: String
    /// Small label in the space bar's corner (settings toggle `spaceLabel`).
    public var spaceCornerLabel: String
    /// Flashed in the middle of the space bar when the keyboard appears.
    public var keyboardName: String
    /// The «back to letters» key on the number and symbol pages.
    public var lettersKey: String
    public var lettersKeyShifted: String
    /// The «back to letters» item in the emoji category bar.
    public var emojiPageLettersKey: String
    /// Action labels; a missing type shows the return icon. `.search`
    /// always draws the magnifying glass — its label only sets the key's
    /// width (KeyboardLayout.returnKeyWeight).
    public var returnLabels: [UIReturnKeyType: String]

    public init(
                space: String,
                spaceCornerLabel: String,
                keyboardName: String,
                lettersKey: String,
                lettersKeyShifted: String,
                emojiPageLettersKey: String,
                returnLabels: [UIReturnKeyType: String]) {
        self.space = space
        self.spaceCornerLabel = spaceCornerLabel
        self.keyboardName = keyboardName
        self.lettersKey = lettersKey
        self.lettersKeyShifted = lettersKeyShifted
        self.emojiPageLettersKey = emojiPageLettersKey
        self.returnLabels = returnLabels
    }
}

public struct TextConventions: Sendable {
    /// The form the canonical palochka is SHOWN in (suggestions, saved
    /// words). Stored rows keep the canonical form. nil shows it as stored.
    public var visiblePalochka: Character?
    /// Letters that never vote in the ALL-CAPS test of a typed prefix.
    public var caseNeutral: Set<Character>
    /// Characters that end the word being typed (tokenizer). The default
    /// is the set the Dagestanian keyboards shipped with.
    public var wordSeparators: CharacterSet
    /// The presentation-only marks around a typed word the keyboard does
    /// not know yet (the quoted literal candidate).
    public var unknownWordOpenQuote: String
    public var unknownWordCloseQuote: String

    /// Whitespace and newlines plus . , ! ? ; : " ' ( ) [ ] { } — – -
    public static let defaultWordSeparators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ".,!?;:\"'()[]{}—–-"))

    public init(visiblePalochka: Character?,
                caseNeutral: Set<Character>,
                wordSeparators: CharacterSet = TextConventions.defaultWordSeparators,
                unknownWordOpenQuote: String = "\u{00AB}",
                unknownWordCloseQuote: String = "\u{00BB}") {
        self.visiblePalochka = visiblePalochka
        self.caseNeutral = caseNeutral
        self.wordSeparators = wordSeparators
        self.unknownWordOpenQuote = unknownWordOpenQuote
        self.unknownWordCloseQuote = unknownWordCloseQuote
    }

    public func visibleForm(_ word: String, canonicalPalochka: Character?) -> String {
        guard let visible = visiblePalochka, let canonical = canonicalPalochka else { return word }
        return word.replacingOccurrences(of: String(canonical), with: String(visible))
    }
}

/// Every native-language string the keyboard draws. Explanatory subtitles
/// that follow the system language stay in the engine's string catalog,
/// except the ones that name the language (supplied here, localized).
public struct KeyboardStrings: Sendable {
    // Suggestion bar
    public var deleteWordQuestion: @Sendable (String) -> String
    public var no: String
    public var delete: String
    // Emoji page
    public var emojiRecents: String
    // Settings panel: chrome
    public var back: String
    public var close: String
    public var settingsCaption: String
    public var settingsTitle: String
    public var pageInput: String
    public var pageTheme: String
    public var pageDictionary: String
    public var pageAbout: String
    // Settings panel: sections
    public var sectionLayout: String
    public var sectionSuggestions: String
    public var sectionKeys: String
    public var sectionLearning: String
    public var sectionLongPress: String
    public var sectionTheme: String
    // Settings panel: toggles
    public var wordSuggestions: String
    public var nextWordSuggestion: String
    public var autoSpace: String
    public var doubleSpacePeriod: String
    public var spaceCursor: String
    public var spaceCornerToggle: String
    public var spaceCornerToggleSubtitle: String
    // Learning speed
    public var learnFast: String
    public var learnNormal: String
    public var learnSlow: String
    /// «N uses», given the engine's threshold for a speed (1, 3, 5).
    public var learnUses: @Sendable (Int) -> String
    // Long-press delay
    public var calloutShort: String
    public var calloutNormal: String
    public var calloutLong: String
    /// The delay in the language's notation, given the engine's seconds.
    public var calloutDuration: @Sendable (Double) -> String
    // Theme
    public var themeSystem: String
    public var themeLight: String
    public var themeDark: String
    // Dictionary page
    public var learnedWordsCaption: String
    public var noWordsYet: String
    public var deleteAll: String
    public var deleteAllQuestion: String
    // About page
    public var aboutInitial: String
    public var aboutTitle: String
    public var aboutByline: @Sendable (String) -> String

    public init(
                deleteWordQuestion: @escaping @Sendable (String) -> String,
                no: String,
                delete: String,
                emojiRecents: String,
                back: String,
                close: String,
                settingsCaption: String,
                settingsTitle: String,
                pageInput: String,
                pageTheme: String,
                pageDictionary: String,
                pageAbout: String,
                sectionLayout: String,
                sectionSuggestions: String,
                sectionKeys: String,
                sectionLearning: String,
                sectionLongPress: String,
                sectionTheme: String,
                wordSuggestions: String,
                nextWordSuggestion: String,
                autoSpace: String,
                doubleSpacePeriod: String,
                spaceCursor: String,
                spaceCornerToggle: String,
                spaceCornerToggleSubtitle: String,
                learnFast: String,
                learnNormal: String,
                learnSlow: String,
                learnUses: @escaping @Sendable (Int) -> String,
                calloutShort: String,
                calloutNormal: String,
                calloutLong: String,
                calloutDuration: @escaping @Sendable (Double) -> String,
                themeSystem: String,
                themeLight: String,
                themeDark: String,
                learnedWordsCaption: String,
                noWordsYet: String,
                deleteAll: String,
                deleteAllQuestion: String,
                aboutInitial: String,
                aboutTitle: String,
                aboutByline: @escaping @Sendable (String) -> String) {
        self.deleteWordQuestion = deleteWordQuestion
        self.no = no
        self.delete = delete
        self.emojiRecents = emojiRecents
        self.back = back
        self.close = close
        self.settingsCaption = settingsCaption
        self.settingsTitle = settingsTitle
        self.pageInput = pageInput
        self.pageTheme = pageTheme
        self.pageDictionary = pageDictionary
        self.pageAbout = pageAbout
        self.sectionLayout = sectionLayout
        self.sectionSuggestions = sectionSuggestions
        self.sectionKeys = sectionKeys
        self.sectionLearning = sectionLearning
        self.sectionLongPress = sectionLongPress
        self.sectionTheme = sectionTheme
        self.wordSuggestions = wordSuggestions
        self.nextWordSuggestion = nextWordSuggestion
        self.autoSpace = autoSpace
        self.doubleSpacePeriod = doubleSpacePeriod
        self.spaceCursor = spaceCursor
        self.spaceCornerToggle = spaceCornerToggle
        self.spaceCornerToggleSubtitle = spaceCornerToggleSubtitle
        self.learnFast = learnFast
        self.learnNormal = learnNormal
        self.learnSlow = learnSlow
        self.learnUses = learnUses
        self.calloutShort = calloutShort
        self.calloutNormal = calloutNormal
        self.calloutLong = calloutLong
        self.calloutDuration = calloutDuration
        self.themeSystem = themeSystem
        self.themeLight = themeLight
        self.themeDark = themeDark
        self.learnedWordsCaption = learnedWordsCaption
        self.noWordsYet = noWordsYet
        self.deleteAll = deleteAll
        self.deleteAllQuestion = deleteAllQuestion
        self.aboutInitial = aboutInitial
        self.aboutTitle = aboutTitle
        self.aboutByline = aboutByline
    }
}

// MARK: - Installation

extension KeyboardDefinition {

    /// The installed keyboard. Reading it before `install(_:)` is a
    /// programming error: the product's principal class installs first.
    public static var current: KeyboardDefinition {
        guard let definition = KeyboardDefinitionRegistry.installed else {
            preconditionFailure("KeyboardDefinition.install(_:) must run before the engine is used")
        }
        KeyboardDefinitionRegistry.wasRead = true
        return definition
    }

    /// Installs the product's definition. Call it from both initializers
    /// of the principal class, before `super.init`.
    ///
    /// Repeating it is safe: iOS creates a new controller each time the
    /// keyboard is shown again in a running extension process, and
    /// installing a definition with the installed `id` again does nothing.
    /// Once the engine has read the definition, its statics keep it for
    /// the life of the process, so a definition with another `id` is
    /// rejected: the installed one stays and Debug builds stop at an
    /// assertion. Before that first read, a later install replaces an
    /// earlier one.
    public static func install(_ definition: KeyboardDefinition) {
        if KeyboardDefinitionRegistry.wasRead, let installed = KeyboardDefinitionRegistry.installed {
            if definition.id != installed.id {
                KeyboardDefinitionRegistry.rejectionHandler(
                    "KeyboardDefinition \(definition.id) installed after the engine read \(installed.id); ignored")
            }
            return
        }
        KeyboardDefinitionRegistry.installed = definition
    }

    /// Whether a definition has been installed in this process.
    public static var isInstalled: Bool { KeyboardDefinitionRegistry.installed != nil }
}

enum KeyboardDefinitionRegistry {
    nonisolated(unsafe) static var installed: KeyboardDefinition?
    nonisolated(unsafe) static var wasRead = false
    /// What a rejected replacement does. Tests swap it to observe the
    /// rejection without trapping.
    nonisolated(unsafe) static var rejectionHandler: (String) -> Void = { assertionFailure($0) }
}

/// The engine's own resources (its en/ru string catalog), for products
/// and diagnostics that need to check the bundle resolved.
public enum GeneralKeyboardResources {
    public static var bundle: Bundle { .module }
}
