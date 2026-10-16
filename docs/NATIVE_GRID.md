# Native iPhone grid (`KeyboardGridModel.nativeCells`)

A keyboard opts in with `LayoutCapabilities(gridModel: .nativeCells)`.
Lezgi uses it. Avar and the reference definition keep the default,
`.weighted`. The grid applies to iPhone portrait only; landscape and iPad
keep the weighted geometry of `KeyboardGeometry.make`.

Code: `KeyboardGeometry.applyNativeCells()` (vertical values, insets) in
`Sources/GeneralKeyboard/Layout/KeyboardGeometry.swift`, and
`RowView.nativeCellWidths` / `nativeSpans` (cells, pixel snapping) in
`Sources/GeneralKeyboard/View/KeyboardView.swift`.

## The model

Measured on Apple's Russian keyboard: iPhone 18 Pro simulator, 402 × 874
pt at 3 px per pt, iOS 27, light theme, every key edge located to a
fraction of a pixel. The model below reproduces all 74 measured key edges
of that keyboard within 0.19 px.

- **Content width** `C = W − 2 × 3.5 pt`.
- **Cells.** Every row is split into cells of `C`:
  - letter, number and symbol rows: in proportion to the key weights, so a
    row of letters is split into equal cells;
  - bottom row: every system key (123, settings, emoji, globe) gets 1/8 of
    `C`, Return 1/4, the space bar the rest. A letter after the space bar
    (`LayoutStyleSpec.bottomRowAfterSpace`, Lezgi's «ъ») takes one letter
    cell of the page's widest letter row, paid half by the space bar and
    half by Return. If the space bar would end up narrower than two letter
    cells, the row falls back to the weights.
- **Keys** are their cell less 3 pt on each side: 6 pt between keys and a
  6.5 pt visible margin at both screen edges.
- **Pixel snapping.** Each key edge is rounded to the nearest physical
  pixel on its own (`displayScale`), half a pixel up, as the native
  keyboard does. Neighbouring keys keep an exact gap while their widths
  differ by a pixel. A 1e-6 px bias keeps float drift in the running sum
  from turning an exact half pixel down.
- **Vertical.** Key height 43 pt, row pitch 54 pt (11 pt gaps), corner
  radius 8 pt: the definition's metrics. Suggestion region 48 pt: natively
  9 pt above the bar, a 32 pt bar and 7 pt below it (but see
  [the workaround](#known-ios-platform-workarounds), which currently moves
  the bar). No slack under the last row.
- **Height** = 48 + rows × 43 + (rows − 1) × 11, computed from the row
  count, never hardcoded: 253 pt for three letter rows plus the bottom row.
  A style with one more row is exactly 54 pt taller, and the live height
  switch keeps working.
- **No under-shade** below the keys in this mode (removed on purpose after
  testing on a device; the weighted mode keeps it).

### Results (Lezgi, iPhone 18 Pro simulator)

- Margins 6.67 pt left, 6.33 pt right, identical to native (key edges at
  20 px and 1187 px).
- 11-key rows: keys 29.67 and 30 pt, identical to native key by key.
  The 12-key top row of Lezgi's `topRow` style: 26.67 and 27 pt.
- Bottom row, widths in pt:

| | 123 | Settings | Emoji | Space | ъ | Return |
|---|---|---|---|---|---|---|
| Lezgi `topRow` | 43.33 | 43.33 | 43.35 | 142.01 | | 93.00 |
| Lezgi `classic` | 43.33 | 43.33 | 43.35 | 124.01 | 30.00 | 75.00 |
| Apple Russian | 43.27 | | 43.32 | 191.34 | | 93.01 |

The space bar is narrower than native because of the settings key, and in
`classic` because of «ъ».

## Known iOS Platform Workarounds

### What iOS controls

On iOS 26 and 27 the system draws two things around a third-party
keyboard that the extension cannot draw into, move or remove:

- the glass **panel** behind the keyboard, including any padding above
  the extension's view;
- the **strip** below it with the globe and dictation buttons.

The extension only draws inside its own view. It cannot draw above it,
and its view, window, safe area and position are the same whether the
system adds padding or not, so it cannot detect that state either.

### Observed differences from Apple's keyboard

Measured on the iPhone 18 Pro simulator (iOS 27) and confirmed on the
owner's iPhone (402 pt wide), Lezgi with a 253 pt view:

| | Apple Russian | Lezgi, opened directly | Lezgi after a globe switch from an Apple keyboard |
|---|---|---|---|
| Panel top edge | 545.5 pt | 545.5 pt | 528.5 pt |
| First row top | 598 pt | 594 pt | 594 pt |
| Last row bottom, above the screen bottom | 71 pt | 75 pt | 75 pt |

1. **Rows 4 pt higher (permanent).** iOS ends a third-party keyboard's
   view 75 pt above the screen bottom; Apple's own keyboard draws its last
   row down to 71 pt. The bottom row already touches the bottom edge of
   the view, so nothing can lower it.
2. **An extra 17 pt above the keyboard (intermittent).** Normally the
   panel starts 0.5 pt above the view, exactly where Apple's panel starts.
   After switching to a third-party keyboard with the globe key from one of
   Apple's keyboards, iOS adds about 17.5 pt of its own panel above the
   view. The keyboard's content does not move; only the system background
   grows upward. Observed behavior:
   - it happens for every third-party keyboard tested (Lezgi at 253 pt,
     GK Reference at 242 pt), whatever the height or grid model;
   - it carries over when switching on to another third-party keyboard,
     and survives leaving the app and coming back;
   - it is gone when the keyboard opens fresh in a newly launched app;
   - a live height change of the keyboard (242 → 296 pt) does not clear
     it.

   Other developers report the same 17 pt on iOS 27 in Apple Developer
   Forums thread 843093
   (<https://developer.apple.com/forums/thread/843093>; FB24460699,
   FB24785360, FB25094825; a related iOS 26 report is FB21449121). Their
   view-hierarchy captures show the host's keyboard container growing by
   17 pt while the extension stays the same; `allowsSelfSizing`,
   `safeAreaRegions = []` and layout requests did not help. No Apple reply
   as of October 2026.

Earlier notes that "the system pads ~15 pt above a third-party keyboard"
were this same effect, measured before the trigger was known.

### Workaround: `temporaryBarLift`

| | |
|---|---|
| Where | `KeyboardGeometry.temporaryBarLift`, applied in `applyNativeCells()` (`Sources/GeneralKeyboard/Layout/KeyboardGeometry.swift`) |
| Value | 8 pt |
| Native placement | 9 pt above the suggestion bar, 7 pt below it |
| Current placement | 1 pt above the suggestion bar, 15 pt below it |
| Unchanged | bar height (32 pt), total keyboard height, letter row positions, key sizes, bottom row |
| Scope | `KeyboardGridModel.nativeCells`, iPhone portrait. Avar, the reference keyboard, iPad and landscape are unaffected |
| Status | temporary iOS workaround, tested and approved on a physical iPhone in October 2026; not part of the native grid model |

**Why.** When the system adds its 17 pt, the space between the panel's top
edge and the suggestion text is far larger than native and looks empty.
The keyboard cannot remove that space, so it moves the suggestion bar up
inside its own view and leaves the same amount under the bar. Centre of
the suggestion bar below the panel's top edge (lift 0 measured, lift 8
derived from it):

| | Native | Lift 0 | Lift 8 |
|---|---|---|---|
| Without the system padding | 25.5 pt | 25.7 pt | 17.7 pt |
| With the system padding | | 42.7 pt | 34.7 pt |

**Disable.** Set `temporaryBarLift = 0`. That restores the native 9 pt /
7 pt placement; nothing else changes.

**When to reconsider.** On every major iOS release, and when Apple
answers the reports above. To check: in a freshly launched app, open the
keyboard directly and note the panel's top edge; then switch to an Apple
keyboard and back with the globe key. If the edge no longer moves up by
17 pt, set the lift to 0.
