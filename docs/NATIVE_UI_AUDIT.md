# Native iOS keyboard UI/UX audit

General Keyboard compared with Apple's built-in Russian keyboard, side by
side, on the same device. The goal is native geometry, look and feel; Avar's
alphabet, both layouts and every language feature stay as they are.

- **Device:** iPhone 18 Pro simulator, iOS 27.0, 402 × 874 pt, 3x.
- **Subjects:** the native «Русская» keyboard; GK Reference and Avar on the
  current General Keyboard engine.
- **Method:** full-resolution screenshots measured by script (pixel rows and
  columns, background segmentation, corner profiles); screen recordings
  decoded frame by frame for timing; touch delivery timed in the extension
  with `systemUptime` against the touch timestamp.
- **Date:** 2026-10-14. Written after Phase 3, before Phase 4.

Status labels: **Fixed** (in this change), **Proposed** (needs approval:
visible change, snapshots would be re-recorded), **Limitation** (platform),
**Not measured**.

## 1. Existing bugs

| # | Finding | Evidence | Status |
|---|---|---|---|
| B1 | **The first emoji row is veiled by a blurred band.** iOS 26 introduced the *scroll edge effect*: a soft, tinted blur that SwiftUI draws along a scroll view's edges where content may pass under a bar. In the keyboard extension it lands on the top edge of the emoji grid, directly under the fixed category title, and covers the whole first row. | Screenshot: the row under «Ахирисел» blurred, rows below sharp; same in dark. Not an inset, safe-area or overlay problem: no view overlaps the grid. | **Fixed:** `scrollEdgeEffectHidden(true)` on the emoji `ScrollView` (iOS 26+ only). First row sharp in light and dark; all 51 snapshots unchanged. |
| B2 | **The key press preview is missing on normal taps.** The key rows used a SwiftUI `DragGesture(minimumDistance: 0)`. In the extension it delivers touch-down 64–100 ms after the finger lands (a UIKit recognizer on the same view: 4–15 ms). On a quick tap, touch-down and touch-up arrive 0.3 ms apart, so neither the pressed key nor the preview reaches the screen; on a 0.3 s press both appear ~90 ms late. | Frame-by-frame recordings: quick tap, no preview frame at all; 0.15 s press, preview shown ~80 ms late. Native: preview on the first frame, ~40 ms for an instant tap. **The released Avar 1.0.0 behaves identically** on the same simulator, so this is not a regression from the GK extraction. The engine code is unchanged since 1.0.0; the likely trigger is iOS 26+ gesture timing (not verified on an older iOS or a device). | **Fixed:** the key rows use a UIKit gesture recognizer (`UIGestureRecognizerRepresentable`, public API, iOS 18+). Measured after: preview visible for 56 ms on a 0.05 s tap, 322 ms on a 0.3 s press, 64 ms on an instant tap; minimum visibility 60 ms, typing itself never delayed. |

Also changed with B2: a press cancelled by the system (for example a
home-indicator swipe that starts on a key) now ends cleanly without typing
anything; long-press callouts, space-bar cursor mode and backspace repeat
were re-verified on the new touch path.

## 2. Visual and geometry differences

Key geometry, measured on the letter rows (points):

| | Native (Russian) | General Keyboard | |
|---|---|---|---|
| Key height | 42.7–43 | 42.3–43 | same |
| Row pitch | 54 | 54 | same |
| Gap between keys | 6 | 6 | same |
| Side margins | 6.7 / 6.3 | 6 / 6 | same within 0.7 |
| Corner radius | ~7.6 | ~7.4 | same |
| Letter key width (11 keys) | 30 | 30 | same (Avar's 12-key top row: 27) |
| Key fill (light) | white | white | same |

| # | Difference | Impact | Proposed correction | Status |
|---|---|---|---|---|
| V1 | **Key preview style.** GK drew the iOS ≤18 bubble with a neck that replaced the key. iOS 26/27 shows a rounded card floating 3.3 pt above the key; the key stays visible in its pressed color. | Looked dated; hid the key while typing. | Card: key width + 24 pt, 64 pt tall, 12 pt continuous corners, key color, letter ~36 pt, slid inward at the screen edges. | **Fixed** (measured: GK card 53.3–54 × 64, same corner profile and gap as native). Top-row cards: see L1. |
| V2 | **Keyboard is 13.6 pt taller** than native (container top 533.7 vs 547.3). The band above the first row is 59.6 pt vs 50.7, and 76 pt vs 71 below the bottom row. | Covers more of the app. | Lower Avar's `totalHeight` (product metrics) and move the rows up ~5 pt. | **Proposed** |
| V3 | **Key shadow.** GK draws a 1.3 pt dark line under every key (RGB ~190); native iOS 27 keys have none. | The most visible "not native" cue. | Remove the shadow (or reduce to near-invisible). | **Proposed** |
| V4 | **Letter label typography.** GK lowercase: 26.4 pt, weight 0.19; glyphs 8% taller, ~40% more ink, and 2 pt below center. Native centers the glyph exactly. | Letters look heavier and sit low. | ~24.5 pt, weight ~0, vertically centered; re-verify Avar digraphs. | **Proposed** |
| V5 | **Bottom row.** Native: 123 (43.3), emoji (43.3), space (191.3), return (93). GK adds the settings key: 123 / gear / emoji 44.3 each, space 166.3, return 66.7. | Return is narrower than native. | Keep the settings key (product feature); consider return ≈ native width, taking the space from the space bar. | **Proposed** |
| V6 | **Pressed key color.** GK RGB (209,214,222), bluish; native (224,224,225), neutral. | Slightly heavier press flash. | Use the native gray. | **Proposed** |
| V7 | **Suggestion bar.** Native: three slots with thin separators, gray text; GK: no separators, black text. Text size the same (11.7 vs 12.3 pt ink). | Reads slightly differently. | Separators and native text color. | **Proposed** |
| V8 | **Long-press callout.** Native iOS 26: key-colored card, selected option on a gray rounded highlight. GK: gray strip, selected option on solid blue. | Old iOS style. | Restyle to the card look (behavior unchanged). | **Proposed** |
| V9 | **Emoji grid.** Native: glyphs ~29 pt, pitch 45.7 × 38.7, uppercase section headers that scroll with the content. GK: 23.5 pt glyphs, pitch 39 × 35, one fixed title. | Emoji look small. | Larger emoji within the current page height; optional inline headers. | **Proposed** |

## 3. Interaction differences

| # | Finding | Status |
|---|---|---|
| I1 | Touch-down latency and preview timing, see B2. | **Fixed** |
| I2 | The suggestion bar and the emoji category bar still use `DragGesture(minimumDistance: 0)`: taps work, but their pressed highlight shows ~90 ms late. | **Proposed:** move them to the same recognizer. |
| I3 | Backspace repeat (0.4 s, then accelerating to 30 ms), space-bar cursor (0.4 s), shift and caps lock, callouts, globe: all work, re-verified after B2. Native timings were not measured. | **Not measured** against native |
| I4 | Return key labels follow the field's `returnKeyType` from the definition; native localizes them by the system language. | Product decision, unchanged |
| I5 | Key click sound and haptic feedback: GK plays none; native follows the user's Sounds & Haptics settings. Apple restricts some feedback in keyboard extensions without Full Access; what exactly works without it must be checked on a device. | **Not measured** |

## 4. Platform limitations

| # | Limitation |
|---|---|
| L1 | A keyboard extension cannot draw above its own view. The native top-row preview reaches into the app; GK's top-row card is shortened to the space above the key (40.5 pt instead of 64), letter scaled to match. |
| L2 | The system emoji keyboard's search field, its taller layout and its system-managed "frequently used" list are not available to third-party keyboards. |
| L3 | The globe and dictation buttons below the keyboard on Face ID iPhones belong to the system; GK shows a globe key only when `needsInputModeSwitchKey` is true, like native. |
| L4 | Audio and haptic feedback without Full Access, see I5. |

## 5. Not measured yet

Landscape; other iPhone sizes (SE, Plus/Max); iPad; older iOS versions;
physical-device touch timing (the simulator injects touches, a finger on
glass may differ); text contexts beyond a plain text field (URL, email,
number pads, search). Each needs a pass before the proposed items ship.

## 6. Changed files

- `Sources/GeneralKeyboard/View/KeyboardView.swift`: UIKit touch recognizer
  for key rows, cancellation handling, preview card, minimum press
  visibility, emoji scroll edge effect.
- `Sources/GeneralKeyboard/Layout/KeyboardLayout.swift`: preview letter font.
- `Tests/GeneralKeyboardTests/KeyPreviewTests.swift`: card geometry (middle,
  edge and top-row keys) and press visibility.
