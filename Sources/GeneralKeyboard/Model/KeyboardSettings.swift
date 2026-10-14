//
//  KeyboardSettings.swift
//  GeneralKeyboard
//
//  User-adjustable keyboard behavior (settings panel, Phase 2). Every
//  default reproduces the pre-settings behavior, so a missing key changes
//  nothing. Values persist in the extension's own UserDefaults.
//

import Foundation

struct KeyboardSettings: Equatable {

    /// Learning speed — only the visibility threshold for learned
    /// suggestions changes, never the learning algorithm itself.
    enum LearnSpeed: String, CaseIterable {
        case fast, normal, conservative

        var minUses: Int {
            switch self {
            case .fast:         return 1
            case .normal:       return 3
            case .conservative: return 5
            }
        }
    }

    /// Delay before the long-press callout with alternative characters
    /// (ӏ, кь, къ…) appears.
    enum CalloutDelay: String, CaseIterable {
        case short, normal, long

        var seconds: TimeInterval {
            switch self {
            case .short:  return 0.2
            case .normal: return 0.3
            case .long:   return 0.45
            }
        }
    }

    /// Keyboard color theme; `.system` follows the host's appearance.
    /// Deliberately named Theme, not Appearance: if animation/size/contrast
    /// settings ever appear, they get an Appearance section of their own
    /// with Theme as one item inside it.
    enum Theme: String, CaseIterable {
        case system, light, dark
    }

    // Suggestions
    var wordSuggestions = true
    var nextWordSuggestions = true
    var autoSpaceAfterSuggestion = true
    // Keys
    var doubleSpacePeriod = true
    var spaceCursor = true
    var spaceLabel = true
    // Learning / long press
    // Fast is the product default: a word learned from the very first
    // use — the deliberate exception to "defaults reproduce pre-settings
    // behavior" (which was the normal/3 threshold).
    var learnSpeed: LearnSpeed = .fast
    var calloutDelay: CalloutDelay = .normal
    // Theme
    var theme: Theme = .system

    // MARK: - Persistence

    private enum Key {
        static let wordSuggestions = "set_wordSuggestions"
        static let nextWordSuggestions = "set_nextWordSuggestions"
        static let autoSpaceAfterSuggestion = "set_autoSpaceAfterSuggestion"
        static let doubleSpacePeriod = "set_doubleSpacePeriod"
        static let spaceCursor = "set_spaceCursor"
        static let spaceLabel = "set_spaceLabel"
        static let learnSpeed = "set_learnSpeed"
        static let calloutDelay = "set_calloutDelay"
        static let theme = "set_theme"
    }

    static func load(from defaults: UserDefaults = .standard) -> KeyboardSettings {
        var settings = KeyboardSettings()
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        settings.wordSuggestions = bool(Key.wordSuggestions, settings.wordSuggestions)
        settings.nextWordSuggestions = bool(Key.nextWordSuggestions, settings.nextWordSuggestions)
        settings.autoSpaceAfterSuggestion = bool(Key.autoSpaceAfterSuggestion, settings.autoSpaceAfterSuggestion)
        settings.doubleSpacePeriod = bool(Key.doubleSpacePeriod, settings.doubleSpacePeriod)
        settings.spaceCursor = bool(Key.spaceCursor, settings.spaceCursor)
        settings.spaceLabel = bool(Key.spaceLabel, settings.spaceLabel)
        if let raw = defaults.string(forKey: Key.learnSpeed),
           let value = LearnSpeed(rawValue: raw) {
            settings.learnSpeed = value
        }
        if let raw = defaults.string(forKey: Key.calloutDelay),
           let value = CalloutDelay(rawValue: raw) {
            settings.calloutDelay = value
        }
        if let raw = defaults.string(forKey: Key.theme),
           let value = Theme(rawValue: raw) {
            settings.theme = value
        }
        return settings
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(wordSuggestions, forKey: Key.wordSuggestions)
        defaults.set(nextWordSuggestions, forKey: Key.nextWordSuggestions)
        defaults.set(autoSpaceAfterSuggestion, forKey: Key.autoSpaceAfterSuggestion)
        defaults.set(doubleSpacePeriod, forKey: Key.doubleSpacePeriod)
        defaults.set(spaceCursor, forKey: Key.spaceCursor)
        defaults.set(spaceLabel, forKey: Key.spaceLabel)
        defaults.set(learnSpeed.rawValue, forKey: Key.learnSpeed)
        defaults.set(calloutDelay.rawValue, forKey: Key.calloutDelay)
        defaults.set(theme.rawValue, forKey: Key.theme)
    }
}
