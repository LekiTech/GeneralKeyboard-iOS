# Rules for working in General Keyboard

Read `../GENERAL_KEYBOARD_PROGRESS.md` first. It records the phase, the
approved decisions, the constraints and the exact next steps. Work proceeds
phase by phase and waits for approval between phases.

## Engine rules

- **Install before use.** `KeyboardDefinition.install(_:)` runs in both
  initializers of the product's `GeneralKeyboardViewController` subclass,
  before `super.init`. Engine statics capture the definition on first use;
  reading it before installation is a `preconditionFailure`. Every new
  controller installs again: the same `id` is a no-op, another `id` after
  first use is rejected (`DefinitionInstallTests`).
- **The engine never spells language data.** No letters, layouts, native
  strings, artifact names, App Group IDs or language names in
  `Sources/GeneralKeyboard`. `EngineNeutralityTests` enforces this; its two
  allowed exceptions (the built-in normalization profile and one frozen
  migration literal) are deliberate.
- **Normalization is data.** A new language gets a `NormalizationProfile`
  value, not an engine edit. The built-in `dagestanianCyrillicV1` profile
  and its `(id, version)` identity are frozen; changing behavior means a new
  profile or a new version.
- **Persisted state is a contract.** Do not change the learned.sqlite
  schema, the outbox format, the UserDefaults keys, the ranking, or the
  storage locations without an approved phase that says so. Never move or
  delete `learned.sqlite`; live data sits in its `-wal` file.
- **Engine strings** use `String(localized:bundle: .module)` and live in
  `Sources/GeneralKeyboard/Resources/Localizable.xcstrings` (en, ru).
  Product strings come from the definition.
- **Swift 5 language mode** for every target. Do not switch to Swift 6 mode
  inside a refactor.

## Tests

- Run the whole suite on an iOS simulator:
  `xcodebuild test -scheme GeneralKeyboard-Package -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0'`
- Test classes that touch the engine derive from `GKTestCase`, which
  installs `ReferenceDefinition`. Tests that build a model use
  `KeyboardTestEnvironment.freshModel`, which empties the learned store in
  place. Never delete database files that a model may hold open.
- Snapshots must match pixel for pixel. Re-record only for an intended
  visual change, with `TEST_RUNNER_RECORD_SNAPSHOTS=1`, and say so in the
  commit.
- `GeneralKeyboardReference` and `Reference/` are dev fixtures. A shipping
  product never links them.

## Process

- Commit only when asked. Never push.
- Unrelated findings go to the backlog in the progress file, not into the
  current change.
