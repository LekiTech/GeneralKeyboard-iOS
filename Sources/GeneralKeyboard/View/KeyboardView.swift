//
//  KeyboardView.swift
//  GeneralKeyboard
//
//  Created by Enver Eskendarov on 6/28/26.
//

import SwiftUI

// MARK: - Dynamic colors matching native iOS keyboard

private extension Color {
    static let kbLetterKey = Color(UIColor(dynamicProvider: { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.227, green: 0.227, blue: 0.235, alpha: 1)
            : UIColor.white
    }))
    static let kbLetterKeyPressed = Color(UIColor(dynamicProvider: { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.36, green: 0.36, blue: 0.37, alpha: 1)
            : UIColor(red: 0.82, green: 0.84, blue: 0.87, alpha: 1)
    }))
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

    private static let strings = KeyboardDefinition.current.strings

    /// Per-style vertical geometry; the view re-renders when the style
    /// changes because `model` is observed.
    private var metrics: KeyboardLayout.Metrics {
        KeyboardLayout.metrics(for: model.layoutStyle)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.page == .emoji {
                emojiPage
            } else {
                VStack(spacing: 8) {
                    suggestionBar
                    GeometryReader { geo in
                        // Vertical budget: 36 bar + 8 gap + N×keyHeight +
                        // (N-1)×rowSpacing = metrics.totalHeight - 1, with
                        // every number from KeyboardLayout.metrics(for:) —
                        // .threeRow keeps the original 250/43/11 untouched,
                        // .fourRow keeps the SAME key size and pays for its
                        // extra row in total height.
                        VStack(spacing: metrics.rowSpacing) {
                            let allRows = model.rows(needsGlobe: model.needsGlobe)
                            ForEach(Array(allRows.enumerated()), id: \.offset) { i, row in
                                rowView(row: row, totalWidth: geo.size.width - 12,
                                        rowIndex: i, totalRows: allRows.count)
                            }
                        }
                        .padding(.horizontal, 6)
                    }
                }
            }

            // Key preview bubble (only when no callout)
            if !isShowingCallout, let cap = pressedCap, case .character = cap {
                KeyPreviewBubble(
                    label: KeyboardLayout.label(for: cap, shifted: model.isShifted,
                                                capsLock: model.isCapsLock),
                    frame: pressedFrame
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
                    isCapsLock: model.isCapsLock
                )
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
        .frame(height: metrics.totalHeight, alignment: .top)
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
        .frame(height: 36)
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
                               : AnyShapeStyle(Color.kbLetterKey),
                    in: Capsule())
        }
    }

    private var suggestionCells: some View {
        let words = paddedSuggestions()
        let visible = Array(words.enumerated().filter { !$0.element.isEmpty })
        return ZStack(alignment: .leading) {
            // Visual layer, no gestures: content-sized cells spread evenly
            // over the bar — every candidate takes the width it needs and
            // the free space splits into the flexible gaps. No separators:
            // the press capsule is the only affordance. Layout is NOT
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
        .frame(height: 36)
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
                        .fill(Color.kbLetterKey)
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
            let rows = metrics.emojiRows
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
                .padding(.horizontal, 6)
                // Transparent areas don't receive touches in SwiftUI; near-zero
                // opacity makes the whole grid area scrollable, not just the glyphs
                .background(Color.white.opacity(0.001))
            }
            .scrollPosition(id: $emojiScrollTarget, anchor: .leading)
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

    private func emojiColumn(_ column: EmojiColumn) -> some View {
        VStack(spacing: 2) {
            ForEach(column.emojis, id: \.self) { emoji in
                Button(action: { onEmojiInsert?(emoji) }) {
                    Text(emoji)
                        .font(.system(size: 26))
                        .frame(width: 38, height: metrics.emojiCellHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(EmojiKeyButtonStyle())
            }
        }
        // Visual gap between categories
        .padding(.trailing, column.endsCategory ? 10 : 0)
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
                    .foregroundColor(Color(UIColor.label))
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
            .foregroundColor(Color(emojiCurrentSection == id ? UIColor.label : UIColor.secondaryLabel))
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(
                Circle()
                    .fill(emojiCurrentSection == id
                          ? Color(UIColor.secondarySystemFill) : Color.clear)
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

    private func rowView(row: [KeyCap], totalWidth: CGFloat,
                         rowIndex: Int = 0, totalRows: Int = 1) -> some View {
        RowView(
            row: row, totalWidth: totalWidth, rowIndex: rowIndex, totalRows: totalRows,
            model: model,
            onKey: onKey,
            onPress: { cap, frame in
                pressedCap = cap
                pressedFrame = frame
            },
            onRelease: { pressedCap = nil },
            onLongPress: { frame, options in
                pressedCap = nil
                calloutFrame = frame
                calloutOptions = options
                let totalW = calloutOptionWidth * CGFloat(options.count)
                let screenWidth = UIScreen.main.bounds.width
                let bubbleX = min(max(frame.midX, totalW / 2 + 6), screenWidth - totalW / 2 - 6)
                let leftX = bubbleX - totalW / 2
                calloutBubbleLeftX = leftX
                let initialLocal = frame.midX - leftX
                calloutSelectedIndex = max(0, min(options.count - 1, Int(initialLocal / calloutOptionWidth)))
                isShowingCallout = true
            },
            onDragMoved: { point in
                let localX = point.x - calloutBubbleLeftX
                let idx = Int(localX / calloutOptionWidth)
                calloutSelectedIndex = max(0, min(calloutOptions.count - 1, idx))
            },
            onLongRelease: {
                if isShowingCallout {
                    let selected = calloutOptions[calloutSelectedIndex]
                    onKey(.character(selected))
                }
                isShowingCallout = false
                calloutOptions = []
            },
            onCursorMove: { steps in onCursorMove?(steps) },
            onCursorLineMove: { lines in onCursorLineMove?(lines) },
            keyHeight: metrics.keyHeight,
            rowSpacing: metrics.rowSpacing
        )
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
        .foregroundColor(Color(UIColor.label))
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
                    .fill(configuration.isPressed ? Color.kbLetterKeyPressed : Color.clear)
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
    let onDragMoved: (CGPoint) -> Void
    let onLongRelease: () -> Void
    let onCursorMove: (Int) -> Void
    let onCursorLineMove: (Int) -> Void

    @State private var rowMinY: CGFloat = 0
    @State private var isPressed = false
    @State private var isLongPressed = false
    @State private var longPressTimer: DispatchWorkItem? = nil
    @State private var repeatTimer: Timer? = nil
    @State private var activeCap: KeyCap? = nil
    @State private var isSpaceCursorMode = false
    @State private var spaceCursorTimer: DispatchWorkItem? = nil
    @State private var spaceLastX: CGFloat = 0
    @State private var spaceLastY: CGFloat = 0

    private let spacing: CGFloat = 6
    /// Style-dependent vertical geometry, injected from
    /// `KeyboardLayout.metrics(for:)` by the parent. `rowSpacing` must
    /// mirror the key-grid `VStack` spacing so the expanded hit zones
    /// tile the inter-row gaps exactly — both come from the same
    /// metrics value, so they cannot drift.
    let keyHeight: CGFloat
    let rowSpacing: CGFloat
    /// Row x-origin in keyboard space; matches `.padding(.horizontal, 6)` on the VStack.
    private let rowLeadingX: CGFloat = 6

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

    /// Visual key frames in keyboard coordinate space.
    private var keyFrames: [(cap: KeyCap, frame: CGRect)] {
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
            HStack(spacing: spacing) {
                ForEach(Array(row.enumerated()), id: \.offset) { _, cap in
                    KeyButton(cap: cap, model: model, returnKeyType: model.returnKeyType,
                              isPressed: activeCap == cap)
                        .frame(width: unitWidth * keyWeight(cap), height: keyHeight)
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear.onAppear {
                        rowMinY = geo.frame(in: .named("keyboard")).minY
                    }
                }
            )

            // Gesture layer: single transparent rect, expanded to cover vertical gaps.
            // Color.clear does not receive touches in SwiftUI; use near-zero opacity instead.
            Color.white.opacity(0.001)
                .frame(height: zoneHeight)
                .offset(y: -topExpand)
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .named("keyboard"))
                        .onChanged { value in handleChanged(value: value) }
                        .onEnded   { _     in handleEnded() }
                )
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

    private func handleChanged(value: DragGesture.Value) {
        guard !isPressed else {
            if isLongPressed {
                onDragMoved(value.location)
            } else if isSpaceCursorMode {
                spaceCursorDragged(to: value.location)
            } else if activeCap == .space {
                // Track the finger before cursor mode kicks in so activation
                // starts from the current position without a jump
                spaceLastX = value.location.x
                spaceLastY = value.location.y
            }
            return
        }
        isPressed = true
        guard let key = nearest(touchX: value.location.x) else { return }
        activeCap = key.cap
        onPress(key.cap, key.frame)

        // Long-press on space enters cursor mode: dragging moves the insertion
        // point (user-disableable in the settings panel)
        if case .space = key.cap, model.settings.spaceCursor {
            spaceLastX = value.location.x
            spaceLastY = value.location.y
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

    }

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
            onLongRelease()
        } else if isSpaceCursorMode {
            // Cursor drag ends without inserting a space
            isSpaceCursorMode = false
            model.isSpaceCursorMode = false
            onRelease()
        } else {
            onRelease()
            if let cap = activeCap { onKey(cap) }
        }
        activeCap = nil
    }
}

// MARK: - Callout bubble

private struct CalloutBubble: View {
    let options: [String]
    let selectedIndex: Int
    let keyFrame: CGRect
    let isShifted: Bool
    let isCapsLock: Bool

    private let optionWidth: CGFloat = 44
    private let bubbleHeight: CGFloat = 54

    var body: some View {
        let totalWidth = optionWidth * CGFloat(options.count)
        // Center bubble over the key
        let bubbleX = min(
            max(keyFrame.midX, totalWidth / 2 + 6),
            UIScreen.main.bounds.width - totalWidth / 2 - 6
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
                    .foregroundColor(i == selectedIndex ? .white : Color(UIColor.label))
                    .frame(width: optionWidth, height: bubbleHeight)
                    .background(i == selectedIndex ? Color.blue : Color.kbLetterKeyPressed)
            }
        }
        .cornerRadius(10)
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: 6, x: 0, y: 3)
        .position(x: bubbleX, y: bubbleY)
    }
}

// MARK: - Key preview bubble

private struct KeyPreviewBubble: View {
    let label: String
    let frame: CGRect

    private let bubbleHeight: CGFloat = 54
    private let neckAboveKey: CGFloat = 11   // gap between bubble bottom and key top

    var body: some View {
        let width = max(frame.width, 44)
        // Neck runs the full key height so the shape replaces the key entirely;
        // capped at frame.maxY so top-row popups stay inside the keyboard view
        let totalHeight = min(bubbleHeight + neckAboveKey + frame.height, frame.maxY)
        ZStack(alignment: .top) {
            KeyPreviewShape(neckWidth: frame.width,
                            bubbleHeight: bubbleHeight,
                            cornerRadius: 8)
                .fill(Color.kbLetterKeyPressed)
                .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
            Text(label)
                .font(.system(size: 28))
                .foregroundColor(Color(UIColor.label))
                .frame(width: width, height: bubbleHeight)
        }
        .frame(width: width, height: totalHeight)
        .position(
            x: frame.midX,
            // Bottom edge aligns with the key bottom
            y: frame.maxY - totalHeight / 2
        )
    }
}

/// One continuous silhouette for the key preview: rounded bubble on top,
/// sides curving inward to a neck matching the pressed key width, flat bottom.
private struct KeyPreviewShape: Shape {
    let neckWidth: CGFloat
    let bubbleHeight: CGFloat
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let inset = max((rect.width - neckWidth) / 2, 0)
        let bubbleBottom = rect.minY + bubbleHeight
        let curveStart = bubbleBottom - 6   // sides begin bending inward
        let curveEnd   = bubbleBottom + 6   // neck sides become vertical

        var p = Path()
        p.move(to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY))
        // top edge + top-right corner
        p.addLine(to: CGPoint(x: rect.maxX - cornerRadius, y: rect.minY))
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + cornerRadius),
                       control: CGPoint(x: rect.maxX, y: rect.minY))
        // right side down, then S-curve inward to neck
        p.addLine(to: CGPoint(x: rect.maxX, y: curveStart))
        p.addCurve(to: CGPoint(x: rect.maxX - inset, y: curveEnd),
                   control1: CGPoint(x: rect.maxX, y: bubbleBottom),
                   control2: CGPoint(x: rect.maxX - inset, y: bubbleBottom))
        // neck right side, rounded bottom corners (key-like), neck left side
        p.addLine(to: CGPoint(x: rect.maxX - inset, y: rect.maxY - cornerRadius))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - inset - cornerRadius, y: rect.maxY),
                       control: CGPoint(x: rect.maxX - inset, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + inset + cornerRadius, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX + inset, y: rect.maxY - cornerRadius),
                       control: CGPoint(x: rect.minX + inset, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + inset, y: curveEnd))
        // S-curve outward back to bubble, left side up
        p.addCurve(to: CGPoint(x: rect.minX, y: curveStart),
                   control1: CGPoint(x: rect.minX + inset, y: bubbleBottom),
                   control2: CGPoint(x: rect.minX, y: bubbleBottom))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY + cornerRadius))
        // top-left corner
        p.addQuadCurve(to: CGPoint(x: rect.minX + cornerRadius, y: rect.minY),
                       control: CGPoint(x: rect.minX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - Single key (visual only — gestures handled by RowView)

private struct KeyButton: View {

    let cap: KeyCap
    @ObservedObject var model: KeyboardModel
    let returnKeyType: UIReturnKeyType
    var isPressed: Bool = false

    var body: some View {
        if case .spacer = cap {
            Color.clear
        } else {
            keyCap
        }
    }

    private var keyCap: some View {
        keyLabel
            // While a character key is pressed its bubble shows the letter,
            // so the key's own label is hidden like on the native keyboard
            .opacity(hidesLabel ? 0 : 1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(backgroundColor)
            .cornerRadius(8)
            .shadow(color: .black.opacity(0.3), radius: 0, x: 0, y: 1)
            .allowsHitTesting(false)
    }

    private var hidesLabel: Bool {
        // Native blanks all key labels while space-drag cursor mode is active
        if model.isSpaceCursorMode { return true }
        if case .character = cap { return isPressed }
        return false
    }

    @ViewBuilder
    private var keyLabel: some View {
        switch cap {

        case .space:
            ZStack(alignment: .bottomTrailing) {
                Color.clear
                Text(verbatim: KeyboardDefinition.current.keys.spaceCornerLabel)
                    .font(.system(size: 10))
                    .foregroundColor(Color(UIColor.systemGray2))
                    .padding(.trailing, 6)
                    .padding(.bottom, 4)
                    // Hidden while the keyboard name flashes, or permanently
                    // via the settings panel
                    .opacity(model.showsKeyboardName || !model.settings.spaceLabel ? 0 : 1)
                if model.showsKeyboardName {
                    // Keyboard name shown centered right after the keyboard appears
                    Text(verbatim: KeyboardDefinition.current.keys.keyboardName)
                        .font(.system(size: 16))
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
                    .font(.system(size: 18))
                    .foregroundColor(Color(UIColor.label))
            } else {
                let text = KeyboardLayout.returnLabel(for: returnKeyType)
                if text.isEmpty {
                    Image(systemName: "return")
                        .font(.system(size: 18))
                        .foregroundColor(Color(UIColor.label))
                } else {
                    // Single line, near-full size: long labels widen the
                    // key (KeyboardLayout.returnKeyWeight) instead of
                    // shrinking the typography; the scale floor only
                    // guards the pathological cases.
                    Text(text)
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .foregroundColor(Color(UIColor.label))
                }
            }

        case .emoji:
            Image(systemName: "face.smiling")
                .font(.system(size: 20))
                .foregroundColor(Color(UIColor.label))

        case .settings:
            Image(systemName: "gearshape")
                .font(.system(size: 20))
                .foregroundColor(Color(UIColor.label))

        case .backspace:
            Image(systemName: "delete.backward")
                .font(.system(size: 18))
                .foregroundColor(Color(UIColor.label))

        case .shift:
            Image(systemName: model.isCapsLock ? "capslock.fill" : (model.isShifted ? "shift.fill" : "shift"))
                .font(.system(size: 18))
                .foregroundColor(Color(UIColor.label))

        default:
            let label = KeyboardLayout.label(for: cap, shifted: model.isShifted,
                                             capsLock: model.isCapsLock)
            Text(label)
                .font(KeyboardLayout.keyLabelFont(for: cap, label: label))
                .foregroundColor(Color(UIColor.label))
        }
    }

    private var backgroundColor: Color {
        // Spacebar is highlighted while it shows the keyboard name, like native
        if case .space = cap, model.showsKeyboardName { return .kbLetterKeyPressed }
        return isPressed ? .kbLetterKeyPressed : .kbLetterKey
    }
}
