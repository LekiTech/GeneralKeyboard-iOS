# Adding a keyboard (draft)

> Draft written in Phase 2. It describes the engine as it is today. The
> first real consumers (Avar in Phase 3, then Lezgi) will turn it into a
> checked procedure; until then, gaps are listed at the end.

A new keyboard is a product repository with two targets: the containing
app and the keyboard extension. Neither contains engine code. The
`Reference/` project in this repository is the smallest complete example;
copy its shape.

**Convention:** a LekiTech keyboard ships exactly these two targets. It has
no iMessage sticker extension, no sticker packs and no messenger
integrations (WhatsApp, Telegram, Instagram or others), so no
`LSApplicationQueriesSchemes` and no third-party packages for them. Avar
and Lezgi shipped sticker packs until 2026-10 and removed them; anything
beyond the two targets needs its own approved feature.

## 1. Project

- Containing app target, bundle ID `org.lekitech.<name>`. Links
  `GeneralKeyboardApp` and `GeneralKeyboardBridge`.
- Keyboard extension target, bundle ID `org.lekitech.<name>.<Extension>`.
  Links `GeneralKeyboard`. Its `Info.plist` declares
  `com.apple.keyboard-service`, the principal class
  `$(PRODUCT_MODULE_NAME).KeyboardViewController`, the keyboard's
  `PrimaryLanguage`, and `RequestsOpenAccess = false`.
- Both targets carry the App Group entitlement `group.org.lekitech.<name>`.
- Swift 5 language mode. iOS 18 minimum.
- The package is added as a Swift package dependency. Keep the bundle IDs
  of a released product unchanged forever.
- No other targets, extensions or packages (see the convention above).

## 2. The definition

One value of `KeyboardDefinition`, usually in its own file
(`<Name>Definition.swift`), built from:

| Part | Type | Supplies |
|---|---|---|
| `id` | `String` | stable identity, e.g. the extension's bundle ID; every distinct definition needs its own |
| `data` | `LanguageData` | App Group ID, the two artifact names (without `.sqlite`), a diagnostics subsystem fallback |
| `layout` | `LayoutCapabilities` | one or more `LayoutStyleSpec` (letter, number and symbol rows, long-press callouts, metrics, settings title and subtitle, character keys after the space bar, quick-switch menu title and subtitle), the default style, whether to show the selector, the UserDefaults key that stores the choice, whether a long press on the settings key opens the style menu, and the iPhone portrait grid model (`.weighted`, or `.nativeCells` for Apple's measured grid, see [NATIVE_GRID.md](NATIVE_GRID.md)) |
| `keys` | `KeyLabels` | space bar text and corner label, keyboard name, letters-key labels, return-key labels per `UIReturnKeyType` |
| `text` | `TextConventions` | the visible palochka (or nil), case-neutral letters, word separators, the quote marks around an unknown word |
| `normalization` | `NormalizationProfile` | script ranges, palochka and its lookalikes, Latin homoglyphs, digraph tails, whether ASCII letters are rejected; identified by `(id, version)` |
| `strings` | `KeyboardStrings` | every native UI string of the keyboard and its settings panel, including a few closures for strings with arguments |
| `emojiCategoryTitles` | `[String: String]` | a title for each emoji category id (`EmojiCatalog.categoryIDs`) |

Layout styles are capabilities. A keyboard offers the styles it supports;
it is never given a style it did not ask for. With one style, the selector
is hidden whatever `showsStyleSelector` says. A stored style that the
keyboard no longer offers falls back to the default.

Generic settings labels (for example "Word suggestions", "layout") are the
engine's and are localized by the package. Everything in `strings` is the
product's.

## 3. The extension's principal class

```swift
import GeneralKeyboard

final class KeyboardViewController: GeneralKeyboardViewController {
    override init(nibName: String?, bundle: Bundle?) {
        KeyboardDefinition.install(MyDefinition.definition)
        super.init(nibName: nibName, bundle: bundle)
    }
    required init?(coder: NSCoder) {
        KeyboardDefinition.install(MyDefinition.definition)
        super.init(coder: coder)
    }
}
```

That is the whole extension, apart from the definition and the artifacts.
iOS creates a new controller each time the keyboard is shown again in a
running extension, so `install` runs many times per process. Installing
the definition with the installed `id` again does nothing; a definition
with another `id` after the engine has started is rejected.

## 4. Artifacts

Two read-only SQLite files in the extension bundle, named as in
`LanguageData`: the words artifact (`words` with `base_score`, plus `meta`)
and the bigrams artifact. Their shape is fixed by
`docs/engine/ARTIFACT_CONTRACT.md`. Every word in them must already be in
the canonical form produced by the keyboard's normalization profile.

Today each product builds them with its own script (Avar:
`scripts/build_dictionaries.py` in its repository).
`scripts/make_reference_artifacts.py` here shows the required output shape.

## 5. The containing app

```swift
import SwiftUI
import GeneralKeyboardApp
import GeneralKeyboardBridge

KeyboardOnboardingView(title: "…", tagline: "…", keyboardName: "<display name>",
                       features: [ … ])
```

The view also takes a trailing closure, a slot between the install card
and the feature cards. It stays empty by default; fill it (for example with
an `OnboardingCard { … }`) only for a separately approved feature, never
for sticker packs or messenger integrations.

`keyboardName` must equal the extension's display name, because the
install steps tell the user to turn it on by that name. Pick up
contribution batches when the app becomes active with
`ContributionInbox.pickUp(from:)` on
`ContributionBridge.productionDirectory(appGroupID:)`.

## 6. Tests every keyboard should have

- `definition.validationErrors()` is empty.
- The persisted-state keys and the definition values that users can see are
  pinned by characterization tests, as Avar does in Phase 1.
- If the keyboard has released before, an upgrade from the released build
  keeps the learned store, its WAL data and every setting.

## Known gaps

- A profile other than `dagestanianCyrillicV1` normalizes correctly, but
  its id is not yet recorded in artifacts or in the learned store (design
  §2.4a). The first such language adds that.
- The generic core of `build_dictionaries.py` and the Python mirror of the
  normalization pipeline are not in this package yet.
- Sentence punctuation (the sentence-ending marks and the closing brackets
  and quotes after them) is still an engine constant.
