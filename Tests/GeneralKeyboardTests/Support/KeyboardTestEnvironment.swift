//
//  KeyboardTestEnvironment.swift
//  GeneralKeyboardTests
//
//  Shared setup for tests that build a real KeyboardModel. The model reads
//  UserDefaults.standard and opens the default learned store exactly as the
//  extension does, so every test starts from a wiped standard domain and an
//  emptied learned.sqlite in the test runner's own container.
//

import Foundation
import UIKit
@testable import GeneralKeyboard
import GeneralKeyboardReference
import XCTest

enum KeyboardTestEnvironment {

    /// Every key the extension persists in UserDefaults.standard
    /// (the persisted-state contract of the Dagestanian keyboards).
    static let persistedKeys = [
        "layoutStyle", "recentEmojis",
        "set_wordSuggestions", "set_nextWordSuggestions", "set_autoSpaceAfterSuggestion",
        "set_doubleSpacePeriod", "set_spaceCursor", "set_spaceLabel",
        "set_learnSpeed", "set_calloutDelay", "set_theme",
    ]

    static func resetPersistentState() {
        for key in persistedKeys { UserDefaults.standard.removeObject(forKey: key) }
        // Empty the default learned store IN PLACE. Deleting learned.sqlite
        // (and its -wal/-shm) would pull the file from under connections
        // that models of earlier tests in this process still hold — SQLite
        // reports that as an API violation and it can wedge the runner.
        LearnedWords()?.reset()
    }

    /// A model built exactly as the extension builds it, after seeding the
    /// persisted state a test needs.
    @MainActor
    static func freshModel(style: LayoutStyle? = .threeRow,
                           recentEmojis: [String] = [],
                           learnedWords: [String] = [],
                           settings: KeyboardSettings? = nil,
                           configure: (KeyboardModel) -> Void = { _ in }) -> KeyboardModel {
        resetPersistentState()
        let defaults = UserDefaults.standard
        if let style { defaults.set(style.rawValue, forKey: "layoutStyle") }
        if !recentEmojis.isEmpty { defaults.set(recentEmojis, forKey: "recentEmojis") }
        settings?.save(to: defaults)
        if !learnedWords.isEmpty, let seed = LearnedWords() {
            for word in learnedWords { seed.learn(word, previous: nil, picked: false) }
        }
        let model = KeyboardModel()
        configure(model)
        return model
    }
}

extension KeyboardSettings {
    /// Defaults with one adjustment, for building persisted fixtures.
    static func with(_ adjust: (inout KeyboardSettings) -> Void) -> KeyboardSettings {
        var settings = KeyboardSettings()
        adjust(&settings)
        return settings
    }
}

/// A minimal host text field: the context before the cursor is all the
/// suggestion and capitalization logic reads.
final class MockTextDocumentProxy: NSObject, UITextDocumentProxy {
    var before: String
    init(before: String = "") { self.before = before }

    var documentContextBeforeInput: String? { before }
    var documentContextAfterInput: String? { nil }
    var selectedText: String? { nil }
    var documentInputMode: UITextInputMode? { nil }
    var documentIdentifier: UUID { UUID() }
    var hasText: Bool { !before.isEmpty }
    var autocapitalizationType: UITextAutocapitalizationType = .sentences
    var returnKeyType: UIReturnKeyType = .default

    func adjustTextPosition(byCharacterOffset offset: Int) {}
    func setMarkedText(_ markedText: String, selectedRange: NSRange) {}
    func unmarkText() {}
    func insertText(_ text: String) { before += text }
    func deleteBackward() { if !before.isEmpty { before.removeLast() } }
}

/// Every engine test runs with the reference keyboard installed. Engine
/// statics capture the definition on first use, so one definition serves
/// the whole test process. Each test class installs it again, as every new
/// keyboard controller does in a running extension; repeating the same
/// definition is a no-op (DefinitionInstallTests).
class GKTestCase: XCTestCase {
    override class func setUp() {
        super.setUp()
        KeyboardDefinition.install(ReferenceDefinition.definition)
    }
}
