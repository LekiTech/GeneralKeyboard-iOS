//
//  ReferenceDefinition.swift
//  GeneralKeyboardReference
//
//  A complete KeyboardDefinition for tests and for the Reference keyboard
//  (Reference/). Every capability is exercised: two layout styles with the
//  selector, a visible palochka, case-neutral letters, the built-in
//  normalization profile. Identity is its own: App Group
//  group.org.lekitech.generalkeyboard and reference_* artifacts.
//

import Foundation
import GeneralKeyboard

public enum ReferenceDefinition {

    /// The full reference keyboard: Avar fixture data, reference identity.
    public static let definition = KeyboardDefinition(
        id: "org.lekitech.generalkeyboard.reference",
        data: LanguageData(
            appGroupID: "group.org.lekitech.generalkeyboard",
            wordsArtifact: "reference_words",
            bigramsArtifact: "reference_bigrams",
            diagnosticsSubsystem: "ReferenceKeyboard"
        ),
        layout: ReferenceLayout.capabilities,
        keys: ReferenceStrings.keys,
        text: TextConventions(
            visiblePalochka: "\u{04C0}",
            caseNeutral: ["\u{04C0}", "\u{04CF}"]
        ),
        normalization: .dagestanianCyrillicV1,
        strings: ReferenceStrings.strings,
        emojiCategoryTitles: ReferenceStrings.emojiCategoryTitles
    )

    /// Capability variants for tests: one style only (no selector), with
    /// a default that differs from the full definition's.
    public static let fourRowOnly: KeyboardDefinition = {
        var d = definition
        d.id = "org.lekitech.generalkeyboard.reference.fourRowOnly"
        d.layout = LayoutCapabilities(styles: [ReferenceLayout.fourRow], defaultStyle: .fourRow,
                                      showsStyleSelector: true, persistenceKey: "layoutStyle")
        return d
    }()

    public static let threeRowOnly: KeyboardDefinition = {
        var d = definition
        d.id = "org.lekitech.generalkeyboard.reference.threeRowOnly"
        d.layout = LayoutCapabilities(styles: [ReferenceLayout.threeRow], defaultStyle: .threeRow,
                                      showsStyleSelector: false, persistenceKey: "layoutStyle")
        return d
    }()

    /// The reference layout data, for tests that pin rows and callouts.
    public static var styles: [LayoutStyleSpec] { ReferenceLayout.capabilities.styles }
}
