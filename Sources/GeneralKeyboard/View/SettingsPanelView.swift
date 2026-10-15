//
//  SettingsPanelView.swift
//  GeneralKeyboard
//
//  Slide-up settings panel inside the keyboard (Phase 1 of the settings
//  plan), opened by the gear key in the bottom row. Pages: home, input
//  behavior, theme, learned-words dictionary, about. Everything stays inside
//  the keyboard extension — no UIKit alerts, no modal presentation; the
//  delete-all confirmation is an in-panel sheet.
//

import SwiftUI

// MARK: - Panel palette

/// The panel lives inside the keyboard, so it wears the keyboard's own
/// neutral colors: the backdrop behind key-colored groups, system
/// separators and label colors. No accent color: a selection is a
/// checkmark in the label color and switches keep the system look.
private extension Color {
    static let spPanel = Color(UIColor.gkKeyboardBackdrop)
    static let spRow = Color(UIColor.gkKeyFill)
    static let spSep = Color(UIColor.opaqueSeparator)
    /// Icon tile in the style of the iOS Settings app's gray tiles.
    static let spIconTile = Color(UIColor.systemGray)
}

// MARK: - Panel

struct SettingsPanelView: View {

    @ObservedObject var model: KeyboardModel
    /// Deletes one learned word (the controller's existing closure).
    var onDeleteWord: ((String) -> Void)? = nil
    /// Wipes all learned data (the controller's existing closure).
    var onResetAll: (() -> Void)? = nil

    enum Page {
        case home, input, theme, dictionary, about
    }

    @State private var stack: [Page] = [.home]
    @State private var showsDeleteAllSheet = false
    @State private var words: [String] = []
    @State private var wordCount = 0

    /// `initialPage` and `showsDeleteAllSheet` exist for snapshot tests;
    /// the keyboard always opens the panel on the home page.
    init(model: KeyboardModel,
         onDeleteWord: ((String) -> Void)? = nil,
         onResetAll: (() -> Void)? = nil,
         initialPage: Page = .home,
         showsDeleteAllSheet: Bool = false) {
        self.model = model
        self.onDeleteWord = onDeleteWord
        self.onResetAll = onResetAll
        if initialPage != .home {
            _stack = State(initialValue: [.home, initialPage])
        }
        _showsDeleteAllSheet = State(initialValue: showsDeleteAllSheet)
    }

    private var page: Page { stack.last ?? .home }

    private static let strings = KeyboardDefinition.current.strings
    private static let layout = KeyboardDefinition.current.layout
    private var strings: KeyboardStrings { Self.strings }

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Capsule()
                    .fill(Color(UIColor.systemGray3))
                    .frame(width: 36, height: 5)
                    .padding(.top, 6)

                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        switch page {
                        case .home:       homePage
                        case .input:      inputPage
                        case .theme:      themePage
                        case .dictionary: dictionaryPage
                        case .about:      aboutPage
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                }
                // Same iOS 26 scroll edge effect as the emoji grid: it veiled
                // the first rows of every page under the header
                .hidingScrollEdgeEffects()
            }

            if showsDeleteAllSheet { deleteAllSheet }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.spPanel)
        .onAppear(perform: refreshWords)
    }

    // MARK: - Header

    private var title: String {
        switch page {
        case .home:       return ""
        case .input:      return strings.pageInput
        case .theme:      return strings.pageTheme
        case .dictionary: return strings.pageDictionary
        case .about:      return strings.pageAbout
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Button {
                if stack.count > 1 {
                    stack.removeLast()
                } else {
                    model.showsSettings = false
                }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                    Text(verbatim: stack.count > 1 ? strings.back : strings.close)
                        .font(.system(size: 16, weight: .medium))
                }
                .foregroundColor(Color(UIColor.label))
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
                .contentShape(Rectangle())
            }
            .frame(minWidth: 110, alignment: .leading)

            Text(verbatim: title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Color(UIColor.label))
                .frame(maxWidth: .infinity)

            Spacer().frame(minWidth: 110)
        }
        .padding(.horizontal, 4)
        .frame(height: 40)
    }

    // MARK: - Pages

    private var homePage: some View {
        Group {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: strings.settingsCaption)
                    .font(.system(size: 11, weight: .bold))
                    .kerning(1.4)
                    .foregroundColor(Color(UIColor.secondaryLabel))
                Text(verbatim: strings.settingsTitle)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundColor(Color(UIColor.label))
            }
            .padding(.horizontal, 2)

            group {
                navRow(icon: "slider.horizontal.3", title: strings.pageInput,
                       value: nil, page: .input)
                divider
                navRow(icon: "circle.lefthalf.filled", title: strings.pageTheme,
                       value: themeTitle(model.settings.theme), page: .theme)
                divider
                navRow(icon: "text.book.closed", title: strings.pageDictionary,
                       value: "\(wordCount)", page: .dictionary)
            }

            group {
                navRow(icon: "info.circle", title: strings.pageAbout,
                       value: BundleInfo.marketingVersion, page: .about)
            }
        }
    }

    /// Input behavior (Phase 2): suggestions, key behaviors, learning speed,
    /// and the long-press callout delay. Only features the keyboard already
    /// has — every control maps 1:1 to a `KeyboardSettings` field.
    private var inputPage: some View {
        Group {
            // Native-language titles come from the keyboard definition and
            // are never localized; the small explanatory subtitles come from
            // the extension's string catalog and follow the user's system
            // language (en fallback).
            // The layout section exists only when the definition offers
            // a choice of styles.
            if Self.layout.showsSelector {
                sectionLabel(strings.sectionLayout + " — " + String(localized: "layout", bundle: .module))
                group {
                    ForEach(Array(Self.layout.styles.enumerated()), id: \.offset) { index, spec in
                        if index > 0 { divider }
                        layoutStyleRow(spec.id, title: spec.settingsTitle,
                                       subtitle: spec.settingsSubtitle)
                    }
                }
            }

            sectionLabel(strings.sectionSuggestions + " — " + String(localized: "suggestions", bundle: .module))
            group {
                toggleRow(title: strings.wordSuggestions,
                          subtitle: String(localized: "Word suggestions", bundle: .module),
                          binding: binding(\.wordSuggestions))
                divider
                toggleRow(title: strings.nextWordSuggestion,
                          subtitle: String(localized: "Next-word suggestion", bundle: .module),
                          binding: binding(\.nextWordSuggestions))
                divider
                toggleRow(title: strings.autoSpace,
                          subtitle: String(localized: "Space after accepting a suggestion", bundle: .module),
                          binding: binding(\.autoSpaceAfterSuggestion))
            }

            sectionLabel(strings.sectionKeys)
            group {
                toggleRow(title: strings.doubleSpacePeriod,
                          subtitle: String(localized: "Double space types a period", bundle: .module),
                          binding: binding(\.doubleSpacePeriod))
                divider
                toggleRow(title: strings.spaceCursor,
                          subtitle: String(localized: "Cursor control with the space bar", bundle: .module),
                          binding: binding(\.spaceCursor))
                divider
                toggleRow(title: strings.spaceCornerToggle,
                          subtitle: strings.spaceCornerToggleSubtitle,
                          binding: binding(\.spaceLabel))
            }

            sectionLabel(strings.sectionLearning + " — " + String(localized: "learning", bundle: .module))
            group {
                learnSpeedRow(.fast, title: strings.learnFast,
                              subtitle: strings.learnUses(KeyboardSettings.LearnSpeed.fast.minUses)
                                  + " · " + String(localized: "after 1 use", bundle: .module))
                divider
                learnSpeedRow(.normal, title: strings.learnNormal,
                              subtitle: strings.learnUses(KeyboardSettings.LearnSpeed.normal.minUses)
                                  + " · " + String(localized: "after 3 uses", bundle: .module))
                divider
                learnSpeedRow(.conservative, title: strings.learnSlow,
                              subtitle: strings.learnUses(KeyboardSettings.LearnSpeed.conservative.minUses)
                                  + " · " + String(localized: "after 5 uses", bundle: .module))
            }

            sectionLabel(strings.sectionLongPress + " — " + String(localized: "long press", bundle: .module))
            group {
                calloutDelayRow(.short, title: strings.calloutShort,
                                subtitle: strings.calloutDuration(KeyboardSettings.CalloutDelay.short.seconds)
                                    + " · " + String(localized: "short delay", bundle: .module))
                divider
                calloutDelayRow(.normal, title: strings.calloutNormal,
                                subtitle: strings.calloutDuration(KeyboardSettings.CalloutDelay.normal.seconds)
                                    + " · " + String(localized: "normal delay", bundle: .module))
                divider
                calloutDelayRow(.long, title: strings.calloutLong,
                                subtitle: strings.calloutDuration(KeyboardSettings.CalloutDelay.long.seconds)
                                    + " · " + String(localized: "long delay", bundle: .module))
            }
        }
    }

    private func learnSpeedRow(_ speed: KeyboardSettings.LearnSpeed,
                               title: String, subtitle: String) -> some View {
        radioRow(title: title, subtitle: subtitle,
                 selected: model.settings.learnSpeed == speed) {
            model.updateSettings { $0.learnSpeed = speed }
        }
    }

    private func calloutDelayRow(_ delay: KeyboardSettings.CalloutDelay,
                                 title: String, subtitle: String) -> some View {
        radioRow(title: title, subtitle: subtitle,
                 selected: model.settings.calloutDelay == delay) {
            model.updateSettings { $0.calloutDelay = delay }
        }
    }

    // MARK: - Theme page

    private var themePage: some View {
        Group {
            sectionLabel(strings.sectionTheme + " — " + String(localized: "theme", bundle: .module))
            group {
                themeRow(.system, title: strings.themeSystem,
                         subtitle: String(localized: "Match the system", bundle: .module))
                divider
                themeRow(.light, title: strings.themeLight,
                         subtitle: String(localized: "Light theme", bundle: .module))
                divider
                themeRow(.dark, title: strings.themeDark,
                         subtitle: String(localized: "Dark theme", bundle: .module))
            }
        }
    }

    /// A tap applies instantly: the controller observes `settings.theme`
    /// and flips `overrideUserInterfaceStyle`, recoloring the keyboard
    /// (panel included) live, with nothing to close or reopen.
    private func themeRow(_ theme: KeyboardSettings.Theme,
                          title: String, subtitle: String) -> some View {
        radioRow(title: title, subtitle: subtitle,
                 selected: model.settings.theme == theme) {
            model.updateSettings { $0.theme = theme }
        }
    }

    private func themeTitle(_ theme: KeyboardSettings.Theme) -> String {
        switch theme {
        case .system: return strings.themeSystem
        case .light:  return strings.themeLight
        case .dark:   return strings.themeDark
        }
    }

    private var dictionaryPage: some View {
        Group {
            VStack(spacing: 2) {
                Text(verbatim: "\(wordCount)")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundColor(Color(UIColor.label))
                Text(verbatim: strings.learnedWordsCaption)
                    .font(.system(size: 13))
                    .foregroundColor(Color(UIColor.secondaryLabel))
            }
            .frame(maxWidth: .infinity)

            if words.isEmpty {
                group {
                    Text(verbatim: strings.noWordsYet)
                        .font(.system(size: 14))
                        .foregroundColor(Color(UIColor.secondaryLabel))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 14)
                }
            } else {
                group {
                    ForEach(Array(words.enumerated()), id: \.element) { index, word in
                        if index > 0 { divider }
                        HStack {
                            Text(verbatim: word)
                                .font(.system(size: 15))
                                .foregroundColor(Color(UIColor.label))
                            Spacer(minLength: 8)
                            Button {
                                onDeleteWord?(word)
                                refreshWords()
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundColor(Color(UIColor.tertiaryLabel))
                                    .frame(width: 34, height: 34)
                                    .contentShape(Rectangle())
                            }
                        }
                        .padding(.leading, 13)
                        .padding(.trailing, 4)
                        .frame(minHeight: 42)
                    }
                }

                group {
                    Button {
                        showsDeleteAllSheet = true
                    } label: {
                        Text(verbatim: strings.deleteAll)
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(.red)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 13)
                            .contentShape(Rectangle())
                    }
                }
            }
        }
    }

    private var aboutPage: some View {
        Group {
            VStack(spacing: 8) {
                Text(verbatim: strings.aboutInitial)
                    .font(.system(size: 28, weight: .heavy))
                    .foregroundColor(.white)
                    .frame(width: 56, height: 56)
                    .background(Color.spIconTile,
                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                VStack(spacing: 2) {
                    Text(verbatim: strings.aboutTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(Color(UIColor.label))
                    Text(verbatim: strings.aboutByline(BundleInfo.marketingVersion))
                        .font(.system(size: 12))
                        .foregroundColor(Color(UIColor.secondaryLabel))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
        }
    }

    // MARK: - Delete-all sheet (in-panel, no UIKit presentation)

    private var deleteAllSheet: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.4)
                .contentShape(Rectangle())
                .onTapGesture { showsDeleteAllSheet = false }

            VStack(spacing: 0) {
                Text(verbatim: strings.deleteAllQuestion)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Color(UIColor.label))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)

                Divider().background(Color.spSep)
                Button {
                    showsDeleteAllSheet = false
                    onResetAll?()
                    refreshWords()
                } label: {
                    Text(verbatim: strings.delete)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.red)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }

                Divider().background(Color.spSep)
                Button {
                    showsDeleteAllSheet = false
                } label: {
                    Text(verbatim: strings.no)
                        .font(.system(size: 16))
                        .foregroundColor(Color(UIColor.label))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
            }
            .background(Color.spRow, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    // MARK: - Building blocks

    private func refreshWords() {
        // One fetch feeds both the list and the counter, so they always
        // agree — see KeyboardModel.savedWords for the filtering rule.
        words = model.savedWords()
        wordCount = words.count
    }

    private func group(@ViewBuilder _ content: () -> some View) -> some View {
        VStack(spacing: 0, content: content)
            .background(Color.spRow, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var divider: some View {
        Rectangle().fill(Color.spSep).frame(height: 1).padding(.leading, 13)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(Color(UIColor.secondaryLabel))
            .padding(.horizontal, 4)
    }

    private func navRow(icon: String, title: String, value: String?, page: Page) -> some View {
        Button {
            stack.append(page)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.white)
                    .frame(width: 28, height: 28)
                    .background(Color.spIconTile, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(verbatim: title)
                    .font(.system(size: 15))
                    .foregroundColor(Color(UIColor.label))
                Spacer(minLength: 8)
                if let value {
                    Text(verbatim: value)
                        .font(.system(size: 14))
                        .foregroundColor(Color(UIColor.secondaryLabel))
                        .lineLimit(1)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Color(UIColor.tertiaryLabel))
            }
            .padding(.horizontal, 13)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
    }

    private func binding(_ keyPath: WritableKeyPath<KeyboardSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.settings[keyPath: keyPath] },
                set: { newValue in model.updateSettings { $0[keyPath: keyPath] = newValue } })
    }

    private func toggleRow(title: String, subtitle: String? = nil,
                           binding: Binding<Bool>) -> some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(.system(size: 15))
                    .foregroundColor(Color(UIColor.label))
                if let subtitle {
                    Text(verbatim: subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(Color(UIColor.secondaryLabel))
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: binding)
                .labelsHidden()
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 8)
        .frame(minHeight: 46)
    }

    private func layoutStyleRow(_ style: LayoutStyle,
                                title: String, subtitle: String) -> some View {
        radioRow(title: title, subtitle: subtitle,
                 selected: model.layoutStyle == style) {
            model.setLayoutStyle(style)
        }
    }

    private func radioRow(title: String, subtitle: String, selected: Bool,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title)
                        .font(.system(size: 15))
                        .foregroundColor(Color(UIColor.label))
                    Text(verbatim: subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(Color(UIColor.secondaryLabel))
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(UIColor.label))
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .frame(minHeight: 46)
            .contentShape(Rectangle())
        }
    }
}
