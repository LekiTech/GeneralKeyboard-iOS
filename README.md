# General Keyboard

The shared iOS keyboard engine behind the LekiTech language keyboards
(Avar, Lezgi, and the ones that follow). A language keyboard is a thin
product: it supplies a `KeyboardDefinition` (layouts, key labels, native UI
strings, dictionary artifacts, App Group, text conventions, normalization
profile) and the engine does the rest.

Shared changes flow one way: **General Keyboard → Avar → Lezgi**.

## Products

| Library | What it is | Linked by |
|---|---|---|
| `GeneralKeyboard` | The engine: model, views, settings panel, emoji, storage (bundled dictionary, static bigrams, learned store, migrations), normalization, contribution outbox, the open `GeneralKeyboardViewController` | the keyboard extension |
| `GeneralKeyboardBridge` | The contribution file protocol shared by the extension and the containing app (App Group directory layout, batch format, inbox pickup) | the extension (through the engine) and the containing app |
| `GeneralKeyboardApp` | The containing app's shared onboarding screen, `KeyboardOnboardingView`, with a slot for product cards | the containing app |
| `GeneralKeyboardReference` | A complete reference `KeyboardDefinition` (Avar fixture data, its own identity). Dev-only | the tests and `Reference/` only, never a shipping product |

Dependencies: `GeneralKeyboard` → `GeneralKeyboardBridge`;
`GeneralKeyboardReference` → `GeneralKeyboard`; `GeneralKeyboardApp` and
`GeneralKeyboardBridge` depend on nothing. No external packages.

Platform: iOS 18+. Swift tools 6.0, Swift 5 language mode on purpose (the
shipping extensions compile in Swift 5 mode; Swift 6 mode adds runtime
isolation checks inside UIKit callbacks).

## Repository layout

```
Package.swift
Sources/
  GeneralKeyboard/            engine (Definition/, Layout/, Model/, View/, Storage/,
                              Emoji/, Contribution/, Host/, Diagnostics/, Resources/)
  GeneralKeyboardBridge/      contribution bridge
  GeneralKeyboardApp/         onboarding screen + its string catalog (en, ru)
  GeneralKeyboardReference/   reference definition + its string catalog
Tests/GeneralKeyboardTests/   unit, characterization, migration and pixel-snapshot tests
  Fixtures/                   frozen production-v1 learned store, reference artifacts
  Snapshots/                  reference PNGs (recorded from released Avar)
Reference/                    GeneralKeyboardReference.xcodeproj: a runnable app +
                              keyboard extension built only from the package
scripts/                      artifact, fixture, emoji and benchmark scripts
docs/                         ADDING_A_KEYBOARD.md; engine/ holds imported engine docs
```

## Using it in a keyboard

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

The definition must be installed before anything in the engine runs, and
never changed afterwards. The step-by-step guide is
[docs/ADDING_A_KEYBOARD.md](docs/ADDING_A_KEYBOARD.md).

## Tests

```bash
xcodebuild test -scheme GeneralKeyboard-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0'
```

The suite installs `ReferenceDefinition` once per process. It includes 51
pixel snapshots recorded from the released Avar keyboard, which must match
exactly. To re-record, set `TEST_RUNNER_RECORD_SNAPSHOTS=1`; a recording
run fails on purpose.

## Reference keyboard

`Reference/GeneralKeyboardReference.xcodeproj` builds `ReferenceApp`
(bundle ID `org.lekitech.generalkeyboard`, display name "GK Reference")
with the `ReferenceKeyboard` extension. It uses the package through a local
reference, signs ad hoc, and is meant for the simulator. It proves that the
engine runs as a real extension with nothing but a definition: resource
bundles resolve inside the `.appex`, the dictionary loads, the learned store
is created and migrated, and the settings panel opens.

```bash
xcodebuild build -project Reference/GeneralKeyboardReference.xcodeproj -scheme ReferenceApp -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0'
```

## Status

Phase 2 of the General Keyboard migration: the package exists and is
validated independently. Avar and Lezgi do not consume it yet (Phase 3 and
later). Project history and next steps live in
`GENERAL_KEYBOARD_PROGRESS.md` and `GENERAL_KEYBOARD_DESIGN.md` next to this
repository.
