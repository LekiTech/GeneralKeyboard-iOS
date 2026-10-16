//
//  KeyboardView.swift
//  GeneralKeyboard
//
//  Created by Enver Eskendarov on 6/28/26.
//

import SwiftUI

// MARK: - Dynamic colors matching native iOS keyboard

/// Colors of the iOS 27 system keyboard, measured on the native Russian
/// keyboard in light and dark (iPhone simulator, RGB on screen). No accent
/// color anywhere: like native, every state is a shade of gray.
private extension Color {
    /// Every key shares one fill, as on iOS 26+: letters, shift, delete,
    /// 123, emoji, settings, globe, space and return. Light keys are opaque
    /// white; dark keys are white at 17% over the backdrop (70,70,70 on the
    /// usual 32,32,32), so the backdrop's tint shows through like native.
    static let kbKey = Color(UIColor(dynamicProvider: { t in
        t.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.17) : .white
    }))
    /// Pressed key: (224,224,225) light; white at 33% dark (106 on the
    /// backdrop).
    static let kbKeyPressed = Color(UIColor(dynamicProvider: { t in
        t.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.33)
            : UIColor(red: 0.878, green: 0.878, blue: 0.882, alpha: 1)
    }))
    /// Surfaces floating over other keys (key preview card, long-press
    /// callout): the key color, opaque so the keys below never show through.
    static let kbFloatingKey = Color(UIColor(dynamicProvider: { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.275, green: 0.275, blue: 0.275, alpha: 1)
            : .white
    }))
    /// The selected option of the long-press callout: a gray rounded
    /// highlight, (228,228,230) light, (92,92,95) dark.
    static let kbCalloutSelection = Color(UIColor(dynamicProvider: { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.361, green: 0.361, blue: 0.373, alpha: 1)
            : UIColor(red: 0.894, green: 0.894, blue: 0.902, alpha: 1)
    }))
    /// Suggestion text: (52,53,60) light, (181,181,181) dark.
    static let kbSuggestionText = Color(UIColor(dynamicProvider: { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.710, green: 0.710, blue: 0.710, alpha: 1)
            : UIColor(red: 0.204, green: 0.208, blue: 0.235, alpha: 1)
    }))
    /// Suggestion bar separator: (206,207,215) light, (49,49,51) dark.
    static let kbSuggestionSeparator = Color(UIColor(dynamicProvider: { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.192, green: 0.192, blue: 0.2, alpha: 1)
            : UIColor(red: 0.808, green: 0.812, blue: 0.843, alpha: 1)
    }))
    /// The small language label in the space bar's corner: (204,204,204)
    /// light, (126,126,126) dark.
    static let kbSpaceCornerLabel = Color(UIColor(dynamicProvider: { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.494, green: 0.494, blue: 0.494, alpha: 1)
            : UIColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1)
    }))
    /// Emoji category bar: the current category's icon (black light,
    /// (160,160,162) dark) on a gray circle ((189,191,202) light, (58,58,59)
    /// dark); the other icons (112,112,116) light, (98,98,98) dark; the
    /// delete icon (42,42,44) light, (193,193,194) dark.
    static let kbEmojiCategorySelected = Color(UIColor(dynamicProvider: { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.627, green: 0.627, blue: 0.635, alpha: 1)
            : .black
    }))
    static let kbEmojiCategoryCircle = Color(UIColor(dynamicProvider: { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.227, green: 0.227, blue: 0.231, alpha: 1)
            : UIColor(red: 0.741, green: 0.749, blue: 0.792, alpha: 1)
    }))
    static let kbEmojiCategory = Color(UIColor(dynamicProvider: { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.384, green: 0.384, blue: 0.384, alpha: 1)
            : UIColor(red: 0.439, green: 0.439, blue: 0.455, alpha: 1)
    }))
    static let kbEmojiBarDelete = Color(UIColor(dynamicProvider: { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.757, green: 0.757, blue: 0.761, alpha: 1)
            : UIColor(red: 0.165, green: 0.165, blue: 0.173, alpha: 1)
    }))
    /// The soft shade under a light key: native light keys darken the
    /// background just below them by ~5% and fade over ~8 pt, with nothing
    /// at the sides; dark keys have none.
    static let kbKeyUnderShade = Color(UIColor(dynamicProvider: { t in
        t.userInterfaceStyle == .dark
            ? .clear
            : UIColor(white: 0, alpha: 0.055)
    }))
}

extension UIColor {
    /// Flat stand-in for the system keyboard backdrop, for surfaces that
    /// must be opaque (a forced theme, the settings panel): (224,225,232)
    /// light, (32,32,32) dark, as measured behind the native keyboard.
    static let gkKeyboardBackdrop = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.125, green: 0.125, blue: 0.125, alpha: 1)
            : UIColor(red: 0.878, green: 0.882, blue: 0.910, alpha: 1)
    }
    /// The opaque key color, for settings rows that sit on the backdrop
    /// like keys: white light, (70,70,70) dark.
    static let gkKeyFill = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.275, green: 0.275, blue: 0.275, alpha: 1)
            : .white
    }
}

// MARK: - Root view

/// SwiftUI rendering of the keyboard: key grid, suggestion bar (including
/// the inline learned-word delete confirmation), emoji page, key preview
/// bubbles and long-press callouts. All state decisions live in
/// `KeyboardModel`; this view only draws and reports gestures via closures.
struct KeyboardView: View {

    @ObservedObject var model: KeyboardModel
    let onKey: (KeyCap) -> Void
    var onSuggestion: ((String) -> Void)? = nil
    var onSuggestionDelete: ((String) -> Void)? = nil
    var onLearnedReset: (() -> Void)? = nil
    var onEmojiInsert: ((String) -> Void)? = nil
    var onCursorMove: ((Int) -> Void)? = nil
    var onCursorLineMove: ((Int) -> Void)? = nil

    // Key preview bubble state
    @State private var pressedCap: KeyCap? = nil
    @State private var pressedFrame: CGRect = .zero
    @State private var pressedAt: CFTimeInterval = 0
    /// Identifies the current press, so a deferred hide never removes the
    /// preview of a newer press.
    @State private var pressToken = 0

    // Suggestion bar press state
    @State private var pressedSuggestionIndex: Int? = nil
    /// Measured cell frames in the "suggestionBar" coordinate space; the
    /// cells are content-sized, so the gesture layer dispatches taps by
    /// these instead of fixed thirds.
    @State private var suggestionCellFrames = [CGRect](repeating: .zero, count: 3)
    @State private var suggestionLongPressWork: DispatchWorkItem? = nil
    @State private var suggestionLongPressFired = false
    /// Learned word awaiting delete confirmation; the bar shows an inline
    /// confirm row while set (UIKit alerts cannot be presented from keyboard
    /// extensions — attempting it kills the keyboard).
    @State private var pendingDeleteWord: String? = nil

    /// `pendingDeleteWord` exists for snapshot tests; the keyboard always
    /// starts with no confirmation showing.
    init(model: KeyboardModel,
         onKey: @escaping (KeyCap) -> Void,
         onSuggestion: ((String) -> Void)? = nil,
         onSuggestionDelete: ((String) -> Void)? = nil,
         onLearnedReset: (() -> Void)? = nil,
         onEmojiInsert: ((String) -> Void)? = nil,
         onCursorMove: ((Int) -> Void)? = nil,
         onCursorLineMove: ((Int) -> Void)? = nil,
         pendingDeleteWord: String? = nil) {
        self.model = model
        self.onKey = onKey
        self.onSuggestion = onSuggestion
        self.onSuggestionDelete = onSuggestionDelete
        self.onLearnedReset = onLearnedReset
        self.onEmojiInsert = onEmojiInsert
        self.onCursorMove = onCursorMove
        self.onCursorLineMove = onCursorLineMove
        _pendingDeleteWord = State(initialValue: pendingDeleteWord)
    }

    // Emoji page state
    @State private var emojiCurrentSection: Int = 0
    @State private var emojiScrollTarget: Int? = nil
    @State private var emojiBarIsPressed = false
    @State private var emojiBarPressedZone: EmojiBarZone? = nil
    @State private var emojiBarRepeatTimer: Timer? = nil

    private enum EmojiBarZone: Equatable {
        case letters
        case backspace
        case category(Int)
    }

    // Callout state
    @State private var calloutFrame: CGRect = .zero
    @State private var calloutOptions: [String] = []
    @State private var calloutSelectedIndex: Int = 0
    @State private var calloutBubbleLeftX: CGFloat = 0
    @State private var isShowingCallout: Bool = false

    private let calloutOptionWidth: CGFloat = 44

    // Quick layout menu (long press on the gear key)
    @State private var isShowingLayoutMenu = false
    @State private var layoutMenuKeyFrame: CGRect = .zero
    /// Rows in display order: the current style first.
    @State private var layoutMenuStyles: [LayoutStyle] = []
    /// Row under the finger; nil outside the menu (releasing changes nothing).
    @State private var layoutMenuHighlight: Int? = nil

    private static let strings = KeyboardDefinition.current.strings

    /// Live geometry for the layout style and the device and orientation
    /// the keyboard is shown in; the view re-renders when either changes
    /// because `model` is observed.
    private var geometry: KeyboardGeometry {
        KeyboardLayout.geometry(for: model.layoutStyle, sizeClass: model.sizeClass)
    }

    /// The keyboard's own width (not the screen's: in landscape the system
    /// insets the keyboard from the screen edges).
    @State private var containerWidth: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.page == .emoji {
                emojiPage
            } else {
                VStack(spacing: geometry.barGap) {
                    suggestionBar
                    GeometryReader { geo in
                        // Vertical budget: bar + gap + N×keyHeight +
                        // (N-1)×rowSpacing = geometry.totalHeight - 1, every
                        // number from KeyboardLayout.geometry(for:sizeClass:);
                        // a 4-row style keeps the same key size and pays for
                        // its extra row in total height.
                        VStack(spacing: geometry.rowSpacing) {
                            let allRows = model.rows(needsGlobe: model.needsGlobe)
                            // Letter columns of the page: the native grid
                            // gives a letter next to the space bar one cell
                            let columns = allRows.dropLast().map(\.count).max() ?? 1
                            ForEach(Array(allRows.enumerated()), id: \.offset) { i, row in
                                rowView(row: row, totalWidth: geo.size.width - 2 * geometry.sideInset,
                                        rowIndex: i, totalRows: allRows.count, columns: columns)
                            }
                        }
                        .padding(.horizontal, geometry.sideInset)
                    }
                }
                .padding(.top, geometry.barTopInset)
            }

            // Key preview card (only when no callout; iPad keyboards have none)
            if geometry.showsKeyPreview, !isShowingCallout,
               let cap = pressedCap, case .character = cap {
                KeyPreviewCard(
                    label: KeyboardLayout.label(for: cap, shifted: model.isShifted,
                                                capsLock: model.isCapsLock),
                    keyFrame: pressedFrame,
                    containerWidth: containerWidth,
                    scale: geometry.keyHeight / 43
                )
                .allowsHitTesting(false)
            }

            // Callout bubble
            if isShowingCallout {
                CalloutBubble(
                    options: calloutOptions,
                    selectedIndex: calloutSelectedIndex,
                    keyFrame: calloutFrame,
                    isShifted: model.isShifted,
                    isCapsLock: model.isCapsLock,
                    containerWidth: containerWidth
                )
                .allowsHitTesting(false)
            }

            // Quick layout menu above the gear key (long press)
            if isShowingLayoutMenu {
                LayoutMenuBubble(styles: layoutMenuStyles,
                                 highlightedIndex: layoutMenuHighlight,
                                 currentStyle: model.layoutStyle,
                                 keyFrame: layoutMenuKeyFrame,
                                 containerWidth: containerWidth)
                    .allowsHitTesting(false)
            }

            // In-keyboard settings panel (gear key), slides up over everything
            if model.showsSettings {
                SettingsPanelView(model: model,
                                  onDeleteWord: onSuggestionDelete,
                                  onResetAll: onLearnedReset)
                    .transition(.move(edge: .bottom))
                    .zIndex(10)
            }
        }
        .animation(.easeOut(duration: 0.28), value: model.showsSettings)
        .frame(height: geometry.totalHeight, alignment: .top)
        // Anchored to the bottom like the native keyboard: while the system
        // resizes the frame after a layout style switch, the keys stay put
        // instead of the grid being cut at both ends
        .frame(maxHeight: .infinity, alignment: .bottom)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
        .coordinateSpace(name: "keyboard")
        .ignoresSafeArea()
    }

    // MARK: - Suggestion bar

    private var suggestionBar: some View {
        Group {
            if let word = pendingDeleteWord {
                deleteConfirmBar(word: word)
            } else {
                suggestionCells
            }
        }
        .frame(height: geometry.barHeight)
        .onChange(of: model.suggestions) { _, _ in
            pendingDeleteWord = nil
        }
    }

    /// Inline confirmation shown in place of the suggestions after a
    /// long-press on a learned word. Stays entirely inside the keyboard view.
    private func deleteConfirmBar(word: String) -> some View {
        HStack(spacing: 12) {
            // Keyboard UI speaks the keyboard's language: «delete word?» —
            // «no» / «delete», all from the definition
            Text(verbatim: Self.strings.deleteWordQuestion(word))
                .font(.system(size: 15))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Spacer(minLength: 0)
            confirmPill(Self.strings.no, emphasized: false) { pendingDeleteWord = nil }
            confirmPill(Self.strings.delete, emphasized: true) {
                pendingDeleteWord = nil
                onSuggestionDelete?(word)
            }
        }
        .padding(.horizontal, 12)
    }

    /// Compact capsule button used by the inline confirmation rows.
    private func confirmPill(_ label: String, emphasized: Bool,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(verbatim: label)
                .font(.system(size: 14, weight: emphasized ? .semibold : .medium))
                .foregroundColor(emphasized ? .red : Color(UIColor.label))
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(
                    emphasized ? AnyShapeStyle(Color.red.opacity(0.12))
                               : AnyShapeStyle(Color.kbKey),
                    in: Capsule())
        }
    }

    private var suggestionCells: some View {
        let words = paddedSuggestions()
        let visible = Array(words.enumerated().filter { !$0.element.isEmpty })
        return ZStack(alignment: .leading) {
            // Visual layer, no gestures: content-sized cells spread evenly
            // over the bar — every candidate takes the width it needs and
            // the free space splits into the flexible gaps, with a native
            // separator in the middle of each gap. Layout is NOT
            // animated here on purpose: a prefix morph animates its own
            // size change (the withAnimation transaction inside
            // MorphingWordText propagates through layout), so evolving
            // words slide naturally while full candidate swaps snap
            // instantly — the bar never drifts on its own.
            HStack(alignment: .center, spacing: 0) {
                Spacer(minLength: 6)
                ForEach(visible, id: \.offset) { item in
                    suggestionCellVisual(item.element, index: item.offset)
                    Spacer(minLength: 6)
                }
            }

            // Separators between neighboring candidates, as on the native
            // bar (iOS 27: 1 pt wide, 23 pt tall, vertically centered),
            // hidden next to a pressed candidate
            ForEach(0..<max(visible.count - 1, 0), id: \.self) { k in
                let left = visible[k].offset, right = visible[k + 1].offset
                let a = suggestionCellFrames[left], b = suggestionCellFrames[right]
                if a.width > 0, b.width > 0,
                   pressedSuggestionIndex != left, pressedSuggestionIndex != right {
                    Rectangle()
                        .fill(Color.kbSuggestionSeparator)
                        .frame(width: 1, height: 23)
                        .position(x: (a.maxX + b.minX) / 2, y: geometry.barHeight / 2)
                }
            }
            .allowsHitTesting(false)

            // Gesture layer: transparent rect covering the whole bar,
            // dispatching by x position to the nearest cell
            Color.white.opacity(0.001)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("suggestionBar"))
                        .onChanged { value in
                            guard let idx = suggestionIndex(at: value.location.x),
                                  pressedSuggestionIndex != idx else { return }
                            pressedSuggestionIndex = idx
                            // Long-press offers to delete a learned suggestion;
                            // dictionary words have nothing to delete
                            suggestionLongPressWork?.cancel()
                            suggestionLongPressFired = false
                            let word = words[idx]
                            if !word.isEmpty, model.isLearnedSuggestion(word) {
                                let work = DispatchWorkItem {
                                    suggestionLongPressFired = true
                                    pressedSuggestionIndex = nil
                                    pendingDeleteWord = word
                                }
                                suggestionLongPressWork = work
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
                            }
                        }
                        .onEnded { value in
                            suggestionLongPressWork?.cancel()
                            suggestionLongPressWork = nil
                            pressedSuggestionIndex = nil
                            guard !suggestionLongPressFired else {
                                suggestionLongPressFired = false
                                return
                            }
                            guard let idx = suggestionIndex(at: value.location.x) else { return }
                            let word = words[idx]
                            guard !word.isEmpty else { return }
                            onSuggestion?(word)
                        }
                )
        }
        .frame(height: geometry.barHeight)
        .coordinateSpace(name: "suggestionBar")
    }

    /// Cell for a bar touch: boundaries lie at the midpoints between
    /// neighboring cells, so the whole bar stays tappable just like the
    /// old fixed thirds.
    private func suggestionIndex(at x: CGFloat) -> Int? {
        let visible = paddedSuggestions().enumerated().filter { !$0.element.isEmpty }
        return visible.min {
            abs(suggestionCellFrames[$0.offset].midX - x)
                < abs(suggestionCellFrames[$1.offset].midX - x)
        }?.offset
    }

    private func paddedSuggestions() -> [String] {
        var s = model.suggestions.isEmpty ? model.fallbackSuggestions : model.suggestions
        while s.count < 3 { s.append("") }
        return s
    }

    /// Bar text size, chosen by on-device comparison of 16/17/18pt.
    private static let suggestionFontSize: CGFloat = 18

    private func suggestionCellVisual(_ word: String, index: Int) -> some View {
        MorphingWordText(word: word, size: Self.suggestionFontSize,
                         quoted: word == model.unrecognizedTyped)
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .background {
                // The pressed highlight hugs the cell content, so it always
                // fully contains the (already truncated) text
                if pressedSuggestionIndex == index {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.kbKey)
                        .padding(.vertical, 4)
                }
            }
            .onGeometryChange(for: CGRect.self) {
                $0.frame(in: .named("suggestionBar"))
            } action: {
                suggestionCellFrames[index] = $0
            }
    }

    // MARK: - Emoji page

    private let emojiRecentsID = -1

    /// One column of up to five emoji in the horizontally scrolling grid.
    ///
    /// The page renders a flat list of these small uniform columns instead of
    /// per-category grids: nested lazy containers defeat laziness — every cell
    /// gets created for layout and the keyboard extension hits its memory limit
    /// on device. Small uniform children keep the `LazyHStack` truly lazy and
    /// scroll jumps precise.
    private struct EmojiColumn: Identifiable {
        let id: Int
        let category: Int      // emojiRecentsID or index into EmojiData.categories
        let endsCategory: Bool
        let emojis: [String]
    }

    private func makeEmojiColumns() -> [EmojiColumn] {
        var groups: [(category: Int, emojis: [String])] = []
        if !model.recentEmojis.isEmpty { groups.append((emojiRecentsID, model.recentEmojis)) }
        for (i, cat) in EmojiData.categories.enumerated() { groups.append((i, cat.emojis)) }

        var columns: [EmojiColumn] = []
        for group in groups {
            let rows = geometry.emojiRows
            let chunks = stride(from: 0, to: group.emojis.count, by: rows).map {
                Array(group.emojis[$0..<min($0 + rows, group.emojis.count)])
            }
            for (ci, chunk) in chunks.enumerated() {
                columns.append(EmojiColumn(id: columns.count,
                                           category: group.category,
                                           endsCategory: ci == chunks.count - 1,
                                           emojis: chunk))
            }
        }
        return columns
    }

    private func emojiSectionTitle(for category: Int) -> String {
        category == emojiRecentsID
            ? Self.strings.emojiRecents
            : KeyboardDefinition.current.emojiCategoryTitles[EmojiData.categories[category].id] ?? ""
    }

    private var emojiPage: some View {
        let columns = makeEmojiColumns()
        return VStack(alignment: .leading, spacing: 0) {
            // Fixed title strip showing the current category, like native
            Text(emojiSectionTitle(for: emojiCurrentSection))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(UIColor.secondaryLabel))
                .padding(.leading, 10)
                .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 2) {
                    ForEach(columns) { column in
                        emojiColumn(column)
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, Self.emojiGridInset)
                // Transparent areas don't receive touches in SwiftUI; near-zero
                // opacity makes the whole grid area scrollable, not just the glyphs
                .background(Color.white.opacity(0.001))
            }
            .scrollPosition(id: $emojiScrollTarget, anchor: .leading)
            .hidingScrollEdgeEffects()
            .padding(.top, 4)
            .onChange(of: emojiScrollTarget) { _, newValue in
                if let id = newValue, columns.indices.contains(id) {
                    emojiCurrentSection = columns[id].category
                }
            }
            .onAppear {
                emojiCurrentSection = model.recentEmojis.isEmpty ? 0 : emojiRecentsID
            }

            Spacer(minLength: 0)

            emojiCategoryBar
        }
    }

    /// Emoji grid closer to the native emoji keyboard (iOS 27: ~29 pt glyphs
    /// on a 45.7 pt column pitch, first glyph ~10 pt from the edge, an extra
    /// ~14 pt between categories). Cell height and row count come from the
    /// geometry, so the page always fits the keyboard's height.
    static let emojiGridInset: CGFloat = 3
    static let emojiCategoryGap: CGFloat = 14

    private func emojiColumn(_ column: EmojiColumn) -> some View {
        VStack(spacing: 2) {
            ForEach(column.emojis, id: \.self) { emoji in
                Button(action: { onEmojiInsert?(emoji) }) {
                    Text(emoji)
                        .font(.system(size: geometry.emojiFontSize))
                        .frame(width: geometry.emojiCellWidth, height: geometry.emojiCellHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(EmojiKeyButtonStyle())
            }
        }
        // Visual gap between categories
        .padding(.trailing, column.endsCategory ? Self.emojiCategoryGap : 0)
    }

    /// Bottom strip like native: АБВ + category icons + delete, no key backgrounds.
    /// A visual layer plus a full-width gesture layer dispatching by x, same as `RowView`.
    private var emojiCategoryBar: some View {
        ZStack {
            // Visual layer, no gestures
            HStack(spacing: 0) {
                Text(verbatim: KeyboardDefinition.current.keys.emojiPageLettersKey)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Color(UIColor.label))
                    .frame(width: 44, height: 36)

                if !model.recentEmojis.isEmpty {
                    emojiCategoryIcon(id: emojiRecentsID, symbol: "clock")
                }
                ForEach(Array(EmojiData.categories.enumerated()), id: \.offset) { i, cat in
                    emojiCategoryIcon(id: i, symbol: cat.icon)
                }

                Image(systemName: "delete.backward")
                    .font(.system(size: 17))
                    .foregroundColor(.kbEmojiBarDelete)
                    .frame(width: 44, height: 36)
            }
            .padding(.horizontal, 4)

            // Gesture layer: covers the bar edge to edge, including gaps around icons
            GeometryReader { geo in
                Color.white.opacity(0.001)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                emojiBarPressBegan(x: value.location.x,
                                                   width: geo.size.width)
                            }
                            .onEnded { _ in
                                emojiBarPressEnded()
                            }
                    )
            }
        }
        .frame(height: 36)
        .padding(.bottom, 4)
    }

    private func emojiCategoryIcon(id: Int, symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 15))
            .foregroundColor(emojiCurrentSection == id ? .kbEmojiCategorySelected : .kbEmojiCategory)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(
                Circle()
                    .fill(emojiCurrentSection == id ? Color.kbEmojiCategoryCircle : Color.clear)
                    .frame(width: 30, height: 30)
            )
    }

    private func emojiBarZone(x: CGFloat, width: CGFloat) -> EmojiBarZone? {
        let side: CGFloat = 48   // 4pt edge padding + 44pt АБВ/delete button
        if x < side { return .letters }
        if x > width - side { return .backspace }

        var ids = Array(EmojiData.categories.indices)
        if !model.recentEmojis.isEmpty { ids.insert(emojiRecentsID, at: 0) }
        let iconWidth = (width - side * 2) / CGFloat(ids.count)
        guard iconWidth > 0 else { return nil }
        let idx = max(0, min(ids.count - 1, Int((x - side) / iconWidth)))
        return .category(ids[idx])
    }

    private func emojiBarPressBegan(x: CGFloat, width: CGFloat) {
        guard !emojiBarIsPressed else { return }
        emojiBarIsPressed = true
        let zone = emojiBarZone(x: x, width: width)
        emojiBarPressedZone = zone

        // Delete repeats while held, same as backspace on the letters page
        if zone == .backspace {
            func scheduleRepeat(interval: TimeInterval) {
                DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
                    guard emojiBarIsPressed else { return }
                    onKey(.backspace)
                    scheduleRepeat(interval: max(0.03, interval * 0.85))
                }
            }
            emojiBarRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                guard emojiBarIsPressed else { return }
                scheduleRepeat(interval: 0.1)
            }
        }
    }

    private func emojiBarPressEnded() {
        emojiBarRepeatTimer?.invalidate()
        emojiBarRepeatTimer = nil
        emojiBarIsPressed = false
        guard let zone = emojiBarPressedZone else { return }
        emojiBarPressedZone = nil

        switch zone {
        case .letters:
            onKey(.letters)
        case .backspace:
            onKey(.backspace)
        case .category(let id):
            emojiCurrentSection = id
            guard let target = makeEmojiColumns().first(where: { $0.category == id })?.id else { return }
            if emojiScrollTarget == target {
                // Binding already holds this id (scrollPosition writes back while the
                // user scrolls) — retrigger so tapping the current category jumps to
                // its start instead of doing nothing
                emojiScrollTarget = nil
                DispatchQueue.main.async { emojiScrollTarget = target }
            } else {
                emojiScrollTarget = target
            }
        }
    }


    // MARK: - Key row

    /// Like the native keyboard, a tap too short to reach the screen still
    /// flashes its preview (native: ~40 ms for an instant tap); a longer
    /// press hides it on release. Typing itself is never delayed.
    static let minimumPressVisibility: CFTimeInterval = 0.06

    private func hidePreview() {
        let remaining = Self.minimumPressVisibility - (CACurrentMediaTime() - pressedAt)
        guard remaining > 0 else { pressedCap = nil; return }
        let token = pressToken
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
            if pressToken == token { pressedCap = nil }
        }
    }

    private func rowView(row: [KeyCap], totalWidth: CGFloat,
                         rowIndex: Int = 0, totalRows: Int = 1, columns: Int = 1) -> some View {
        RowView(
            row: row, totalWidth: totalWidth, rowIndex: rowIndex, totalRows: totalRows,
            model: model,
            onKey: onKey,
            onPress: { cap, frame in
                pressToken &+= 1
                pressedAt = CACurrentMediaTime()
                pressedCap = cap
                pressedFrame = frame
            },
            onRelease: { hidePreview() },
            onLongPress: { frame, options in
                pressedCap = nil
                calloutFrame = frame
                calloutOptions = options
                let totalW = calloutOptionWidth * CGFloat(options.count)
                let bubbleX = min(max(frame.midX, totalW / 2 + 6), containerWidth - totalW / 2 - 6)
                let leftX = bubbleX - totalW / 2
                calloutBubbleLeftX = leftX
                let initialLocal = frame.midX - leftX
                calloutSelectedIndex = max(0, min(options.count - 1, Int(initialLocal / calloutOptionWidth)))
                isShowingCallout = true
            },
            onSettingsLongPress: { frame in
                pressedCap = nil
                layoutMenuKeyFrame = frame
                let offered = KeyboardDefinition.current.layout.styles.map(\.id)
                layoutMenuStyles = [model.layoutStyle] + offered.filter { $0 != model.layoutStyle }
                layoutMenuHighlight = nil
                isShowingLayoutMenu = true
            },
            onDragMoved: { point in
                if isShowingLayoutMenu {
                    // Track the row under the finger; outside the card, none
                    let rect = LayoutMenuBubble.menuFrame(keyFrame: layoutMenuKeyFrame,
                                                          rows: layoutMenuStyles.count,
                                                          containerWidth: containerWidth)
                    if rect.insetBy(dx: -8, dy: -4).contains(point) {
                        let row = Int((point.y - rect.minY) / LayoutMenuBubble.rowHeight)
                        layoutMenuHighlight = max(0, min(layoutMenuStyles.count - 1, row))
                    } else {
                        layoutMenuHighlight = nil
                    }
                    return
                }
                let localX = point.x - calloutBubbleLeftX
                let idx = Int(localX / calloutOptionWidth)
                calloutSelectedIndex = max(0, min(calloutOptions.count - 1, idx))
            },
            onLongRelease: { commit in
                if isShowingLayoutMenu {
                    if commit, let index = layoutMenuHighlight {
                        model.setLayoutStyle(layoutMenuStyles[index])
                    }
                    isShowingLayoutMenu = false
                    layoutMenuHighlight = nil
                    return
                }
                if commit, isShowingCallout {
                    let selected = calloutOptions[calloutSelectedIndex]
                    onKey(.character(selected))
                }
                isShowingCallout = false
                calloutOptions = []
            },
            onCursorMove: { steps in onCursorMove?(steps) },
            onCursorLineMove: { lines in onCursorLineMove?(lines) },
            spacing: geometry.keyGap,
            keyHeight: geometry.keyHeight,
            rowSpacing: geometry.rowSpacing,
            rowLeadingX: geometry.sideInset,
            cornerRadius: geometry.cornerRadius,
            labelScale: geometry.labelScale,
            usesNativeCells: geometry.usesNativeCells,
            cellOuterPad: geometry.cellOuterPad,
            cellKeyInset: geometry.cellKeyInset,
            columns: columns
        )
    }
}

// MARK: - Scroll edge effect

extension View {
    /// iOS 26 draws a soft "scroll edge effect" (a blurred, tinted band)
    /// along a scroll view's edges when the system decides content may sit
    /// under a bar. Inside the keyboard extension it lands on the emoji
    /// grid's top edge and veils the whole first row; the grid has no bar
    /// to separate from, so the effect is hidden. Earlier systems have no
    /// such effect.
    @ViewBuilder func hidingScrollEdgeEffects() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }
}

// MARK: - Morphing suggestion text

/// Suggestion-cell text that mimics the native keyboard's per-glyph
/// candidate morph (TUIPredictionViewCell's UIMorphingLabel): when a word
/// is extended or shortened while typing (shared prefix), the retained
/// letters slide to their new centered positions and the added/removed
/// letter fades — while a completely different word swaps instantly, like
/// the native plain-label path. Rendering is per-character `Text`s with
/// positional identity, so inter-letter kerning is lost — imperceptible
/// for SF at this size. Purely visual: gestures and hit testing live on
/// the bar's own layers.
private struct MorphingWordText: View {

    let word: String
    let size: CGFloat
    /// Presentation-only «…» around the word — the native keyboard's mark
    /// for a literal candidate it does not recognize (Cyrillic locales use
    /// guillemets there). The quotes render outside the per-character
    /// ForEach, so glyph identity and the morph animation are unaffected,
    /// and `word` itself stays undecorated everywhere.
    let quoted: Bool

    /// The word currently rendered; follows `word` with or without
    /// animation depending on how the old and new values relate.
    @State private var displayed: String

    /// False for a single frame after a full-word swap: every glyph starts
    /// transparent and slightly enlarged, then settles to normal with a
    /// per-position delay — the native bar's left-to-right ripple for a
    /// newly appearing candidate (its private per-glyph UIMorphingLabel is
    /// the machinery behind that effect). Purely visual: the glyphs are
    /// laid out instantly, opacity/scaleEffect never touch layout or
    /// hit-testing, and the prefix morph path never flips this.
    @State private var glyphsSettled = true

    private static let openQuote = KeyboardDefinition.current.text.unknownWordOpenQuote
    private static let closeQuote = KeyboardDefinition.current.text.unknownWordCloseQuote

    init(word: String, size: CGFloat, quoted: Bool = false) {
        self.word = word
        self.size = size
        self.quoted = quoted
        _displayed = State(initialValue: word)
    }

    var body: some View {
        ViewThatFits {
            HStack(spacing: 0) {
                if quoted { Text(verbatim: Self.openQuote) }
                ForEach(Array(displayed.enumerated()), id: \.offset) { index, ch in
                    Text(String(ch))
                        .transition(.opacity)
                        .opacity(glyphsSettled ? 1 : 0)
                        .scaleEffect(glyphsSettled ? 1 : 1.15)
                        // A whisper of vertical settle (from just below) so
                        // the appearance reads as organic motion, not pure
                        // scaling. Render-only, like the other two.
                        .offset(y: glyphsSettled ? 0 : 1.5)
                        .animation(.easeOut(duration: 0.2)
                            .delay(Double(index) * 0.022),
                            value: glyphsSettled)
                }
                if quoted { Text(verbatim: Self.closeQuote) }
            }
            // Words too wide for the cell fall back to a plain text with
            // no morph, shrinking a little before truncating — words in
            // agglutinative languages run long, and a slightly smaller whole word beats losing
            // its ending to an ellipsis.
            Text(verbatim: quoted ? Self.openQuote + displayed + Self.closeQuote : displayed)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .font(.system(size: size))
        .foregroundColor(.kbSuggestionText)
        .onChange(of: word) { old, new in
            let morphs = !old.isEmpty && !new.isEmpty
                && (new.hasPrefix(old) || old.hasPrefix(new))
            if morphs {
                withAnimation(.easeOut(duration: 0.2)) { displayed = new }
            } else {
                // A completely new word: glyphs take their final layout
                // immediately (no bar drift), hidden and slightly enlarged —
                // then settle left to right on the next runloop tick.
                var instant = Transaction()
                instant.disablesAnimations = true
                withTransaction(instant) {
                    displayed = new
                    glyphsSettled = false
                }
                DispatchQueue.main.async { glyphsSettled = true }
            }
        }
    }
}

// MARK: - Emoji key press highlight

/// Rounded key-colored flash behind an emoji while touched, like native.
/// `ButtonStyle` gets `isPressed` for free and plays nice with the `ScrollView`.
private struct EmojiKeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? Color.kbKeyPressed : Color.clear)
            )
    }
}

// MARK: - Row view with expanded hit zones

private struct RowView: View {

    let row: [KeyCap]
    let totalWidth: CGFloat
    let rowIndex: Int
    let totalRows: Int
    @ObservedObject var model: KeyboardModel
    let onKey: (KeyCap) -> Void
    let onPress: (KeyCap, CGRect) -> Void
    let onRelease: () -> Void
    let onLongPress: (CGRect, [String]) -> Void
    /// Long press on the gear key, when the keyboard offers the quick
    /// layout menu.
    let onSettingsLongPress: (CGRect) -> Void
    let onDragMoved: (CGPoint) -> Void
    /// Ends a long press; `false` when the touch was cancelled by the
    /// system (nothing is inserted).
    let onLongRelease: (Bool) -> Void
    let onCursorMove: (Int) -> Void
    let onCursorLineMove: (Int) -> Void

    @State private var rowMinY: CGFloat = 0
    @State private var isPressed = false
    @State private var isLongPressed = false
    @State private var longPressTimer: DispatchWorkItem? = nil
    @State private var repeatTimer: Timer? = nil
    @State private var activeCap: KeyCap? = nil
    @State private var pressStartedAt: CFTimeInterval = 0
    @State private var pressToken = 0
    @State private var isSpaceCursorMode = false
    @State private var spaceCursorTimer: DispatchWorkItem? = nil
    @State private var spaceLastX: CGFloat = 0
    @State private var spaceLastY: CGFloat = 0

    /// Horizontal gap between keys and the row's x-origin in keyboard
    /// space (matches the rows' horizontal padding), from the geometry.
    let spacing: CGFloat
    /// Style-dependent vertical geometry, injected from
    /// `KeyboardLayout.geometry(for:sizeClass:)` by the parent. `rowSpacing` must
    /// mirror the key-grid `VStack` spacing so the expanded hit zones
    /// tile the inter-row gaps exactly — both come from the same
    /// geometry value, so they cannot drift.
    let keyHeight: CGFloat
    let rowSpacing: CGFloat
    let rowLeadingX: CGFloat
    let cornerRadius: CGFloat
    let labelScale: CGFloat
    /// The native cell grid (KeyboardGridModel.nativeCells); see
    /// `nativeSpans`. `columns` is the page's widest letter row.
    let usesNativeCells: Bool
    let cellOuterPad: CGFloat
    let cellKeyInset: CGFloat
    let columns: Int

    @Environment(\.displayScale) private var displayScale

    /// Per-key width in row units; the return key adapts to its label.
    private func keyWeight(_ cap: KeyCap) -> CGFloat {
        cap == .return
            ? KeyboardLayout.returnKeyWeight(for: model.returnKeyType)
            : KeyboardLayout.weight(cap)
    }

    private var unitWidth: CGFloat {
        let totalWeight = row.map { keyWeight($0) }.reduce(0, +)
        let totalSpacingPts = spacing * CGFloat(row.count - 1)
        return (totalWidth - totalSpacingPts) / totalWeight
    }
    private var topExpand:    CGFloat { rowIndex == 0             ? 0 : rowSpacing / 2 }
    private var bottomExpand: CGFloat { rowIndex == totalRows - 1 ? 0 : rowSpacing / 2 }
    private var zoneHeight:   CGFloat { keyHeight + topExpand + bottomExpand }

    /// Cell widths of this row in the native grid; they add up to the
    /// content width `c`.
    private func nativeCellWidths(content c: CGFloat) -> [CGFloat] {
        let proportional: [CGFloat] = {
            let total = row.map { keyWeight($0) }.reduce(0, +)
            return row.map { c * keyWeight($0) / total }
        }()
        // Letter, number and symbol rows: cells in proportion to the key
        // weights, so a row of letters is split into equal cells
        guard row.contains(.space) else { return proportional }
        // Bottom row, as on the native keyboard: every system key 1/8 of the
        // content width, return 1/4, the space bar the rest. A letter next
        // to the space bar takes one letter cell, paid for half by the space
        // bar and half by return.
        let letterCell = c / CGFloat(max(columns, 1))
        let letterCount = row.filter { if case .character = $0 { return true }; return false }.count
        let lettersWidth = letterCell * CGFloat(letterCount)
        let systemCount = row.count - letterCount - row.filter { $0 == .space || $0 == .return }.count
        let returnCell = c / 4 - lettersWidth / 2
        let spaceCell = c - CGFloat(systemCount) * c / 8 - returnCell - lettersWidth
        // A row too crowded for the native proportions keeps the weights
        guard spaceCell >= 2 * letterCell else { return proportional }
        return row.map { cap in
            switch cap {
            case .space: return spaceCell
            case .return: return returnCell
            case .character: return letterCell
            default: return c / 8
            }
        }
    }

    /// Key spans in keyboard coordinates in the native grid: each key is its
    /// cell less the key inset per side, every edge rounded to the pixel
    /// grid on its own (so neighbouring keys keep an exact gap while their
    /// widths differ by a pixel, as on the native keyboard).
    private var nativeSpans: [(minX: CGFloat, maxX: CGFloat)] {
        let c = totalWidth - 2 * cellOuterPad
        let scale = max(displayScale, 1)
        // Half a pixel rounds up, as natively; the hair keeps float drift in
        // the running sum from turning an exact half pixel down
        func snap(_ v: CGFloat) -> CGFloat { (v * scale + 1e-6).rounded(.toNearestOrAwayFromZero) / scale }
        var x = rowLeadingX + cellOuterPad
        return nativeCellWidths(content: c).map { w in
            defer { x += w }
            return (snap(x + cellKeyInset), snap(x + w - cellKeyInset))
        }
    }

    /// Visual key frames in keyboard coordinate space.
    private var keyFrames: [(cap: KeyCap, frame: CGRect)] {
        if usesNativeCells {
            return zip(row, nativeSpans).map { cap, span in
                (cap, CGRect(x: span.minX, y: rowMinY, width: span.maxX - span.minX, height: keyHeight))
            }
        }
        var result: [(KeyCap, CGRect)] = []
        var x = rowLeadingX
        for cap in row {
            let kw = unitWidth * keyWeight(cap)
            result.append((cap, CGRect(x: x, y: rowMinY, width: kw, height: keyHeight)))
            x += kw + spacing
        }
        return result
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Visual layer
            Group {
                if usesNativeCells {
                    // Explicit pixel-snapped frames (the row starts at the
                    // keyboard's left edge, itself on the pixel grid)
                    let spans = nativeSpans
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(row.enumerated()), id: \.offset) { i, cap in
                            KeyButton(cap: cap, model: model, returnKeyType: model.returnKeyType,
                                      isPressed: activeCap == cap, cornerRadius: cornerRadius,
                                      labelScale: labelScale, showsUnderShade: false)
                                .frame(width: spans[i].maxX - spans[i].minX, height: keyHeight)
                                .offset(x: spans[i].minX - rowLeadingX)
                        }
                    }
                    .frame(width: totalWidth, height: keyHeight, alignment: .topLeading)
                } else {
                    HStack(spacing: spacing) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cap in
                            KeyButton(cap: cap, model: model, returnKeyType: model.returnKeyType,
                                      isPressed: activeCap == cap, cornerRadius: cornerRadius,
                                      labelScale: labelScale)
                                .frame(width: unitWidth * keyWeight(cap), height: keyHeight)
                        }
                    }
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear {
                        rowMinY = geo.frame(in: .named("keyboard")).minY
                    }
                }
            )

            // Touch layer: one rect over the whole row, expanded to cover the
            // vertical gaps. UIKit, not a SwiftUI DragGesture: see KeyTouchSurface.
            Color.white.opacity(0.001)
                .frame(height: zoneHeight)
                .offset(y: -topExpand)
                .gesture(KeyTouchSurface(
                    onBegan: { handleChanged(location: $0) },
                    onMoved: { handleChanged(location: $0) },
                    onEnded: { handleEnded() },
                    onCancelled: { handleCancelled() }
                ))
        }
        .frame(height: keyHeight)  // keep layout height at 43pt so VStack spacing is unchanged
    }

    /// A touch inside a key's visual frame wins; gaps fall back to the nearest `midX`.
    private func nearest(touchX: CGFloat) -> (cap: KeyCap, frame: CGRect)? {
        if let hit = keyFrames.first(where: { $0.frame.minX <= touchX && touchX <= $0.frame.maxX }) {
            return hit
        }
        return keyFrames.min(by: { abs($0.frame.midX - touchX) < abs($1.frame.midX - touchX) })
    }

    private func handleChanged(location: CGPoint) {
        guard !isPressed else {
            if isLongPressed {
                onDragMoved(location)
            } else if isSpaceCursorMode {
                spaceCursorDragged(to: location)
            } else if activeCap == .space {
                // Track the finger before cursor mode kicks in so activation
                // starts from the current position without a jump
                spaceLastX = location.x
                spaceLastY = location.y
            }
            return
        }
        isPressed = true
        guard let key = nearest(touchX: location.x) else { return }
        activeCap = key.cap
        pressToken &+= 1
        pressStartedAt = CACurrentMediaTime()
        onPress(key.cap, key.frame)

        // Long-press on space enters cursor mode: dragging moves the insertion
        // point (user-disableable in the settings panel)
        if case .space = key.cap, model.settings.spaceCursor {
            spaceLastX = location.x
            spaceLastY = location.y
            let work = DispatchWorkItem {
                guard isPressed else { return }
                isSpaceCursorMode = true
                model.isSpaceCursorMode = true
            }
            spaceCursorTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
        }

        // Backspace hold-to-repeat with acceleration
        if case .backspace = key.cap {
            func scheduleRepeat(interval: TimeInterval) {
                DispatchQueue.main.asyncAfter(deadline: .now() + interval) {
                    guard isPressed else { return }
                    onKey(.backspace)
                    scheduleRepeat(interval: max(0.03, interval * 0.85))
                }
            }
            repeatTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                guard isPressed else { return }
                scheduleRepeat(interval: 0.1)
            }
        }

        // Long-press for character keys that have callout options
        if case .character(let s) = key.cap,
           let extras = KeyboardLayout.callouts(style: model.layoutStyle)[s.lowercased()],
           !extras.isEmpty {
            let base = s.lowercased()
            let opts = [base] + extras.filter { $0.lowercased() != base }
            let frame = key.frame
            let work = DispatchWorkItem {
                isLongPressed = true
                onLongPress(frame, opts)
            }
            longPressTimer = work
            // The callout delay is user-adjustable in the settings panel
            DispatchQueue.main.asyncAfter(deadline: .now() + model.settings.calloutDelay.seconds,
                                          execute: work)
        }

        // Long press on the gear: the quick layout menu (a tap still opens
        // the settings panel; it fires in handleEnded only when no long
        // press was triggered)
        if case .settings = key.cap, KeyboardDefinition.current.layout.showsQuickSwitch {
            let frame = key.frame
            let work = DispatchWorkItem {
                isLongPressed = true
                onSettingsLongPress(frame)
            }
            longPressTimer = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.quickSwitchDelay, execute: work)
        }
    }

    /// Hold time before the gear key opens the quick layout menu.
    static let quickSwitchDelay: TimeInterval = 0.35

    /// 8pt of horizontal movement moves the cursor one character; 30pt vertically, one line.
    private func spaceCursorDragged(to point: CGPoint) {
        let stepWidth: CGFloat = 8
        let steps = Int((point.x - spaceLastX) / stepWidth)
        if steps != 0 {
            onCursorMove(steps)
            spaceLastX += CGFloat(steps) * stepWidth
        }

        let stepHeight: CGFloat = 30
        let lineSteps = Int((point.y - spaceLastY) / stepHeight)
        if lineSteps != 0 {
            onCursorLineMove(lineSteps)
            spaceLastY += CGFloat(lineSteps) * stepHeight
        }
    }

    private func handleEnded() {
        longPressTimer?.cancel()
        longPressTimer = nil
        spaceCursorTimer?.cancel()
        spaceCursorTimer = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
        isPressed = false

        if isLongPressed {
            isLongPressed = false
            onLongRelease(true)
        } else if isSpaceCursorMode {
            // Cursor drag ends without inserting a space
            isSpaceCursorMode = false
            model.isSpaceCursorMode = false
            onRelease()
        } else {
            onRelease()
            if let cap = activeCap { onKey(cap) }
        }
        clearHighlight()
    }

    /// The pressed key stays highlighted at least as long as its preview
    /// (KeyboardView.minimumPressVisibility), unless a new press began.
    private func clearHighlight() {
        let remaining = KeyboardView.minimumPressVisibility - (CACurrentMediaTime() - pressStartedAt)
        guard remaining > 0 else { activeCap = nil; return }
        let token = pressToken
        DispatchQueue.main.asyncAfter(deadline: .now() + remaining) {
            if pressToken == token, !isPressed { activeCap = nil }
        }
    }

    /// The system took the touch (for example a home-indicator swipe that
    /// started on a key): undo the press without typing anything.
    private func handleCancelled() {
        longPressTimer?.cancel()
        longPressTimer = nil
        spaceCursorTimer?.cancel()
        spaceCursorTimer = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
        isPressed = false
        if isLongPressed {
            isLongPressed = false
            onLongRelease(false)
        }
        if isSpaceCursorMode {
            isSpaceCursorMode = false
            model.isSpaceCursorMode = false
        }
        onRelease()
        activeCap = nil
    }
}

// MARK: - Key touch surface

/// The touch layer of a key row. A SwiftUI `DragGesture(minimumDistance: 0)`
/// reports the press about 85-100 ms after the finger lands, and a quick
/// tap only when it lifts, so the pressed key and its preview showed late
/// or never; a UIKit recognizer sees the same touch in a few milliseconds
/// (measured in the keyboard extension, iOS 27). This one acts on raw
/// touches instead of waiting to be recognized. It tracks one touch at a
/// time, like the gesture it replaces, and reports points in the
/// "keyboard" coordinate space.
private struct KeyTouchSurface: UIGestureRecognizerRepresentable {
    let onBegan: (CGPoint) -> Void
    let onMoved: (CGPoint) -> Void
    let onEnded: () -> Void
    let onCancelled: () -> Void

    func makeUIGestureRecognizer(context: Context) -> KeyTouchRecognizer {
        KeyTouchRecognizer()
    }

    func updateUIGestureRecognizer(_ recognizer: KeyTouchRecognizer, context: Context) {
        let converter = context.converter
        recognizer.toKeyboard = { touch in
            converter.convert(globalPoint: touch.location(in: nil), to: .named("keyboard"))
        }
        recognizer.onBegan = onBegan
        recognizer.onMoved = onMoved
        recognizer.onEnded = onEnded
        recognizer.onCancelled = onCancelled
    }
}

private final class KeyTouchRecognizer: UIGestureRecognizer {
    var toKeyboard: (UITouch) -> CGPoint = { _ in .zero }
    var onBegan: (CGPoint) -> Void = { _ in }
    var onMoved: (CGPoint) -> Void = { _ in }
    var onEnded: () -> Void = {}
    var onCancelled: () -> Void = {}
    private weak var tracked: UITouch?

    init() {
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracked == nil, let touch = touches.first else { return }
        tracked = touch
        state = .began
        onBegan(toKeyboard(touch))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = tracked, touches.contains(touch) else { return }
        state = .changed
        onMoved(toKeyboard(touch))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = tracked, touches.contains(touch) else { return }
        tracked = nil
        state = .ended
        onEnded()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = tracked, touches.contains(touch) else { return }
        tracked = nil
        state = .cancelled
        onCancelled()
    }

    override func reset() {
        super.reset()
        tracked = nil
    }
}

// MARK: - Callout bubble

private struct CalloutBubble: View {
    let options: [String]
    let selectedIndex: Int
    let keyFrame: CGRect
    let isShifted: Bool
    let isCapsLock: Bool
    let containerWidth: CGFloat

    private let optionWidth: CGFloat = 44
    private let bubbleHeight: CGFloat = 54

    var body: some View {
        let totalWidth = optionWidth * CGFloat(options.count)
        // Center bubble over the key
        let bubbleX = min(
            max(keyFrame.midX, totalWidth / 2 + 6),
            containerWidth - totalWidth / 2 - 6
        )
        // Once the long-press interface is active the connection to the
        // key disappears: the options bubble floats clean, no neck. Its
        // position is unchanged from the necked version (center 34pt
        // above the key top), so only the connection vanishes.
        let desiredY = keyFrame.minY - 34
        let bubbleY = max(desiredY, bubbleHeight / 2)

        return HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, opt in
                let display = isShifted
                    ? KeyboardLayout.applyCase(opt, capsLock: isCapsLock)
                    : opt
                Text(display)
                    .font(.system(size: 24))
                    .foregroundColor(Color(UIColor.label))
                    .frame(width: optionWidth, height: bubbleHeight)
                    .background {
                        // iOS 26+: a key-colored card, the selected option
                        // on a gray rounded highlight inside it
                        if i == selectedIndex {
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(Color.kbCalloutSelection)
                                .padding(4)
                        }
                    }
            }
        }
        .background(Color.kbFloatingKey,
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
        .position(x: bubbleX, y: bubbleY)
    }
}

// MARK: - Quick layout menu

/// The quick layout menu above the gear key: one row per style, the current
/// style first and checked. The row under the finger is highlighted and
/// releasing on it switches the style. Same iOS 26 look as the long-press
/// callout: a key-colored card, the highlight a gray rounded rectangle.
private struct LayoutMenuBubble: View {
    let styles: [LayoutStyle]
    let highlightedIndex: Int?
    let currentStyle: LayoutStyle
    let keyFrame: CGRect
    let containerWidth: CGFloat

    static let menuWidth: CGFloat = 196
    static let rowHeight: CGFloat = 52
    private static let gap: CGFloat = 8   // between the card and the key top

    /// Card frame in keyboard coordinates, shared with the drag hit testing.
    static func menuFrame(keyFrame: CGRect, rows: Int, containerWidth: CGFloat) -> CGRect {
        let height = rowHeight * CGFloat(rows)
        let x = min(max(keyFrame.minX, 4), containerWidth - menuWidth - 4)
        let y = max(keyFrame.minY - gap - height, 2)
        return CGRect(x: x, y: y, width: menuWidth, height: height)
    }

    var body: some View {
        let rect = Self.menuFrame(keyFrame: keyFrame, rows: styles.count,
                                  containerWidth: containerWidth)
        let layout = KeyboardDefinition.current.layout
        return VStack(spacing: 0) {
            ForEach(Array(styles.enumerated()), id: \.element) { index, style in
                let spec = layout.spec(for: style)
                row(title: spec.quickSwitchTitle ?? spec.settingsTitle,
                    subtitle: spec.quickSwitchSubtitle ?? spec.settingsSubtitle,
                    isCurrent: style == currentStyle,
                    isHighlighted: highlightedIndex == index)
                    .overlay(alignment: .top) {
                        if index > 0 {
                            Rectangle()
                                .fill(Color.kbSuggestionSeparator)
                                .frame(height: 1)
                                .padding(.horizontal, 12)
                        }
                    }
            }
        }
        .frame(width: Self.menuWidth)
        .background(Color.kbFloatingKey,
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .compositingGroup()
        .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 2)
        .position(x: rect.midX, y: rect.midY)
    }

    private func row(title: String, subtitle: String,
                     isCurrent: Bool, isHighlighted: Bool) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Color(UIColor.label))
                Text(verbatim: subtitle)
                    .font(.system(size: 11))
                    .foregroundColor(Color(UIColor.secondaryLabel))
            }
            Spacer(minLength: 0)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(UIColor.label))
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 13)
        .frame(width: Self.menuWidth, height: Self.rowHeight)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.kbCalloutSelection)
                    .padding(4)
            }
        }
    }
}

// MARK: - Key preview card

/// The key preview of the iOS 26+ system keyboard: a rounded card in the
/// key color floating just above the pressed key (no neck), showing the
/// character large while the key itself stays visible in its pressed
/// color. Geometry measured on the native Russian keyboard, iOS 27,
/// iPhone 18 Pro: card = key width + 24 pt, 64 pt tall, 12 pt corners,
/// 3.5 pt above the key, kept inside the screen; letter ~36 pt.
///
/// The system clips a keyboard extension at the top of its own view (the
/// native card reaches into the app above; ours cannot), so a top-row
/// card is as tall as the room above the key allows, letter scaled with it.
struct KeyPreviewCard: View {
    let label: String
    let keyFrame: CGRect
    let containerWidth: CGFloat
    /// Key height relative to the iPhone portrait key (43 pt): the card and
    /// its letter shrink with smaller keys (iPhone landscape).
    var scale: CGFloat = 1

    static let extraWidth: CGFloat = 24
    static let height: CGFloat = 64
    static let cornerRadius: CGFloat = 12
    static let gapAboveKey: CGFloat = 3.5
    static let letterSize: CGFloat = 36

    /// The card's frame in keyboard coordinates.
    static func frame(keyFrame: CGRect, containerWidth: CGFloat, scale: CGFloat = 1) -> CGRect {
        let width = keyFrame.width + extraWidth
        // Edge keys: the card slides inward so it never leaves the keyboard
        let midX = min(max(keyFrame.midX, width / 2), containerWidth - width / 2)
        let bottom = keyFrame.minY - gapAboveKey
        let h = max(min((height * scale).rounded(), bottom), 0)
        return CGRect(x: midX - width / 2, y: bottom - h, width: width, height: h)
    }

    /// The letter shrinks with a top-row card that had to be shortened.
    static func letterSize(cardHeight: CGFloat, scale: CGFloat = 1) -> CGFloat {
        let full = letterSize * scale
        return min(full, full * cardHeight / (height * scale) + 8)
    }

    var body: some View {
        let card = Self.frame(keyFrame: keyFrame, containerWidth: containerWidth, scale: scale)
        Text(label)
            .font(KeyboardLayout.previewFont(label: label,
                                             size: Self.letterSize(cardHeight: card.height,
                                                                   scale: scale)))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundColor(Color(UIColor.label))
            .padding(.horizontal, 4)
            .frame(width: card.width, height: card.height)
            .background(
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .fill(Color.kbFloatingKey)
                    .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1)
            )
            .position(x: card.midX, y: card.midY)
    }
}

// MARK: - Single key (visual only — gestures handled by RowView)

private struct KeyButton: View {

    let cap: KeyCap
    @ObservedObject var model: KeyboardModel
    let returnKeyType: UIReturnKeyType
    var isPressed: Bool = false
    var cornerRadius: CGFloat = 8
    var labelScale: CGFloat = 1
    /// The soft shade below light keys; the native cell grid draws none.
    var showsUnderShade: Bool = true

    private func size(_ points: CGFloat) -> CGFloat { points * labelScale }

    var body: some View {
        if case .spacer = cap {
            Color.clear
        } else {
            keyCap
        }
    }

    private var keyCap: some View {
        keyLabel
            .opacity(hidesLabel ? 0 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(backgroundColor)
            .cornerRadius(cornerRadius)
            // No hard drop shadow (native keys have none); light keys get the
            // native soft shade below them instead
            .background(alignment: .bottom) {
                if showsUnderShade {
                    LinearGradient(colors: [Color.kbKeyUnderShade, .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 8)
                        .offset(y: 8)
                }
            }
            .allowsHitTesting(false)
    }

    private var hidesLabel: Bool {
        // Native blanks all key labels while space-drag cursor mode is
        // active. A pressed character key keeps its label: since iOS 26 the
        // preview card floats above the key instead of replacing it.
        model.isSpaceCursorMode
    }

    @ViewBuilder
    private var keyLabel: some View {
        switch cap {

        case .space:
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                Text(verbatim: KeyboardDefinition.current.keys.spaceCornerLabel)
                    .font(.system(size: size(10)))
                    .foregroundColor(.kbSpaceCornerLabel)
                    .padding(.trailing, 6)
                    .padding(.bottom, 4)
                    // Hidden while the keyboard name flashes, or permanently
                    // via the settings panel
                    .opacity(model.showsKeyboardName || !model.settings.spaceLabel ? 0 : 1)
                if model.showsKeyboardName {
                    // Keyboard name shown centered right after the keyboard appears
                    Text(verbatim: KeyboardDefinition.current.keys.keyboardName)
                        .font(.system(size: size(16)))
                        .foregroundColor(Color(UIColor.label))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.25), value: model.showsKeyboardName)

        case .return:
            if returnKeyType == .search {
                // The universal search icon: drawn as an SF Symbol like
                // every other key icon so it matches the native look —
                // a color emoji would not.
                Image(systemName: "magnifyingglass")
                    .font(.system(size: size(18)))
                    .foregroundColor(Color(UIColor.label))
            } else {
                let text = KeyboardLayout.returnLabel(for: returnKeyType)
                if text.isEmpty {
                    Image(systemName: "return")
                        .font(.system(size: size(18)))
                        .foregroundColor(Color(UIColor.label))
                } else {
                    // Single line, near-full size: long labels widen the
                    // key (KeyboardLayout.returnKeyWeight) instead of
                    // shrinking the typography; the scale floor only
                    // guards the pathological cases.
                    Text(text)
                        .font(.system(size: size(14)))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundColor(Color(UIColor.label))
                }
            }

        case .emoji:
            Image(systemName: "face.smiling")
                .font(.system(size: size(20)))
                .foregroundColor(Color(UIColor.label))

        case .settings:
            Image(systemName: "gearshape")
                .font(.system(size: size(20)))
                .foregroundColor(Color(UIColor.label))

        case .backspace:
            Image(systemName: "delete.backward")
                .font(.system(size: size(18)))
                .foregroundColor(Color(UIColor.label))

        case .shift:
            Image(systemName: model.isCapsLock ? "capslock.fill" : (model.isShifted ? "shift.fill" : "shift"))
                .font(.system(size: size(18)))
                .foregroundColor(Color(UIColor.label))

        default:
            let label = KeyboardLayout.label(for: cap, shifted: model.isShifted,
                                             capsLock: model.isCapsLock)
            Text(label)
                .font(KeyboardLayout.keyLabelFont(for: cap, label: label, scale: labelScale))
                .foregroundColor(Color(UIColor.label))
                .offset(y: KeyboardLayout.labelBaselineShift(for: cap, label: label, scale: labelScale))
        }
    }

    private var backgroundColor: Color {
        // Spacebar is highlighted while it shows the keyboard name, like native
        if case .space = cap, model.showsKeyboardName { return .kbKeyPressed }
        return isPressed ? .kbKeyPressed : .kbKey
    }
}
