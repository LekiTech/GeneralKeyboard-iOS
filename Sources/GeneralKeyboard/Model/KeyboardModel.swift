//
//  KeyboardModel.swift
//  GeneralKeyboard
//
//  Created by Enver Eskendarov on 6/28/26.
//

import UIKit
import Combine
import GeneralKeyboardBridge

enum ShiftState {
    case off, once, capsLock
}

/// The keyboard's brain: page and shift state, key handling, composed-word
/// tracking, suggestion generation with shared capitalization, and the
/// on-device learning hooks. Rendering lives in `KeyboardView`, the UIKit
/// bridge in `KeyboardViewController`. See docs/CODEBASE_OVERVIEW.md.
final class KeyboardModel: ObservableObject {

    @Published var page: KeyboardPage = .letters
    @Published var shiftState: ShiftState = .once
    @Published var suggestions: [String] = []
    @Published var returnKeyType: UIReturnKeyType = .default
    @Published var needsGlobe: Bool = false
    /// Device and orientation the keyboard is shown in; the host controller
    /// updates it on layout, and the geometry follows.
    @Published var sizeClass: KeyboardSizeClass = .phonePortrait
    /// Space long-press trackpad mode; key labels hide while the cursor is dragged.
    @Published var isSpaceCursorMode: Bool = false
    /// Keyboard name shown centered on the spacebar right after the keyboard appears.
    @Published var showsKeyboardName: Bool = false
    /// The in-keyboard settings panel (opened by the gear key) is visible.
    @Published var showsSettings: Bool = false
    /// Which letter grid is active — one of the styles the keyboard
    /// definition offers; user-selectable in the settings panel when it
    /// offers several, persisted in the extension's own UserDefaults under
    /// the definition's key. A stored value the definition does not offer
    /// falls back to its default. The suggestion engine never reads it —
    /// every style inserts identical text.
    @Published var layoutStyle: LayoutStyle = KeyboardDefinition.current.layout.resolve(
        UserDefaults.standard.string(forKey: KeyboardModel.layoutStyleKey))

    private static let layoutStyleKey = KeyboardDefinition.current.layout.persistenceKey

    func setLayoutStyle(_ style: LayoutStyle) {
        layoutStyle = style
        UserDefaults.standard.set(style.rawValue, forKey: Self.layoutStyleKey)
    }

    /// User-adjustable behavior (settings panel, Phase 2); defaults keep the
    /// pre-settings behavior.
    @Published var settings = KeyboardSettings.load()

    init() {
        learned?.minVisibleUses = settings.learnSpeed.minUses
    }

    /// Applies and persists a settings change; effects that have model-side
    /// state are synced here so the change is felt immediately.
    func updateSettings(_ transform: (inout KeyboardSettings) -> Void) {
        transform(&settings)
        settings.save()
        learned?.minVisibleUses = settings.learnSpeed.minUses
        if !settings.wordSuggestions {
            suggestions = []
            learnedDisplayWords = []
            fallbackSuggestions = []
        }
    }

    var isShifted: Bool { shiftState != .off }
    var isCapsLock: Bool { shiftState == .capsLock }

    private let wordDB = WordSuggestions()
    /// Corpus-derived context (pairs from the av-ru dictionary's example
    /// sentences since content_version 2). Every path through it degrades
    /// to a no-op when the artifact is empty or missing.
    private let staticBigrams = StaticBigrams()
    private let learned = LearnedWords()
    private var lastSpaceTap: Date? = nil

    /// The word being typed, tracked locally: `documentContextBeforeInput`
    /// lags behind fast typing (it round-trips through the host app), so the
    /// suggestion tap must not rely on it alone to know how many characters
    /// to replace. Resynced from the context on every `textDidChange`.
    private(set) var composedWord = ""

    /// The most recent completed word of the current sentence, tracked
    /// synchronously (the proxy context lags) — the source for Stage 4
    /// next-word suggestions. nil right after `.` `!` `?` or return, so
    /// next-word suggestions never cross a sentence boundary.
    private var lastCompletedWord: String?

    /// Realigns the local buffers once the host has confirmed the document
    /// state (cursor moves, field switches, our own edits landing).
    func syncComposedWord(proxy: UITextDocumentProxy) {
        learnWordCommittedByHostClear(proxy: proxy)
        composedWord = wordPrefix(proxy: proxy)
        lastCompletedWord = previousWord(proxy: proxy)
        // The cursor moved on from the word just accepted from the bar —
        // the acceptance settles as final (metrics, best effort).
        if let pending = pendingAcceptedWord, lastCompletedWord != pending {
            pendingAcceptedWord = nil
        }
        // A host-confirmed state change disarms the auto-space swallow —
        // unless it is just our own acceptance edit landing (context still
        // ends with the word + space), which some hosts report through
        // textDidChange too. Same best-effort pattern as above.
        if let word = autoSpacedAcceptedWord,
           proxy.documentContextBeforeInput?.hasSuffix(word + " ") != true {
            autoSpacedAcceptedWord = nil
        }
    }

    /// Sending a message usually clears the field without the word ever
    /// getting a trailing space, so it would never be learned. A clear is
    /// visible to the extension: the host's edit fires `textDidChange` (our
    /// own edits keep `composedWord` in sync before any event arrives) and
    /// the document turns completely empty. That signal commits the word
    /// being composed. Deliberately narrow: cursor moves and edits leave
    /// text in the document and never trigger; the rare false positives
    /// (a search field's clear button, tapping into another empty field)
    /// are absorbed by the 3-confirmation visibility threshold.
    private func learnWordCommittedByHostClear(proxy: UITextDocumentProxy) {
        guard !composedWord.isEmpty, !proxy.hasText else { return }
        recordManualCompletion()
        learned?.learn(composedWord, previous: lastCompletedWord, picked: false)
    }

    /// Display forms of the current suggestions that came from the learned
    /// store — the only ones long-press deletion applies to.
    private(set) var learnedDisplayWords: Set<String> = []

    /// Bundled-dictionary candidates for a prefix, reordered by static
    /// corpus context when the previous word is known.
    ///
    /// The reorder is a **stable** sort on the static weight alone: rows
    /// without a pair keep weight 0 and therefore keep the order SQLite
    /// produced (base_score, then length). With an empty artifact `weights`
    /// is always empty and this returns the SQL order untouched — the
    /// degradation the equivalence tests pin down.
    private func rankedDictionaryWords(for prefix: String, previous: String?) -> [String] {
        let words = wordDB?.suggestions(for: prefix) ?? []
        guard let previous, let staticBigrams, !staticBigrams.isEmpty, words.count > 1
        else { return words }
        let weights = staticBigrams.weights(after: previous, candidates: words)
        guard !weights.isEmpty else { return words }
        return words.enumerated()
            .sorted { lhs, rhs in
                let lw = weights[lhs.element] ?? 0
                let rw = weights[rhs.element] ?? 0
                return lw == rw ? lhs.offset < rhs.offset : lw > rw
            }
            .map(\.element)
    }

    /// The raw typed word currently leading the bar as a literal candidate
    /// because neither the bundled dictionary nor the visible learned words
    /// recognize it. Presentation-only marker: the suggestion value stays
    /// undecorated (tap, learning, deletion counts all see the raw word) —
    /// the view alone wraps this word in «…», like the native keyboard.
    @Published private(set) var unrecognizedTyped: String?

    /// Merges learned words (best first) with the bundled dictionary.
    /// Both use the Cyrillic palochka `ӏ`, so deduplication is a plain
    /// case-insensitive comparison. Both kinds follow the capitalization
    /// context of the word being typed.
    ///
    /// The prefix is the locally composed word, not the proxy context: the
    /// context lags behind our own edits, which used to resurface the just
    /// completed word as if it were still being typed.
    func updateSuggestions(proxy: UITextDocumentProxy) {
        // Master switch: with word suggestions off the bar shows nothing
        // (learning itself continues — it is a separate concern)
        guard settings.wordSuggestions else {
            suggestions = []
            learnedDisplayWords = []
            fallbackSuggestions = []
            unrecognizedTyped = nil
            return
        }
        let prefix = composedWord
        guard !prefix.isEmpty else {
            // Stage 4: with no active prefix, suggest likely next words from
            // the learned bigrams of the last completed word. When there is
            // no last word (sentence start) or no confident pairs, the bar
            // falls back to the random dictionary words.
            let personalNext = settings.nextWordSuggestions
                ? (lastCompletedWord.flatMap { learned?.nextWords(after: $0) } ?? [])
                : []
            // Personal context always wins. The bundled corpus only speaks
            // when personal learning has nothing to say, so a global
            // statistic can never displace what this user actually types.
            let staticNext = (settings.nextWordSuggestions && personalNext.isEmpty)
                ? (lastCompletedWord.flatMap { staticBigrams?.nextWords(after: $0) } ?? [])
                : []
            var display: [String] = []
            var learnedSet: Set<String> = []
            for word in personalNext {
                let form = displayForm(word, prefix: "", proxy: proxy)
                display.append(form)
                learnedSet.insert(form)   // deletable by long press
            }
            for word in staticNext {
                // Not added to learnedSet: a corpus word is not the user's
                // to delete.
                display.append(displayForm(word, prefix: "", proxy: proxy))
            }
            // Entering the idle state (nothing typed, no next words) rolls a
            // fresh random trio, so erasing text never resurfaces the same
            // idle words. Only the transition rolls — while the bar stays
            // idle the words hold still (updateSuggestions also fires on
            // cursor moves and host resyncs).
            let isIdle = display.isEmpty
            if isIdle && !barWasIdle {
                fallbackWords = wordDB?.randomWords(3) ?? []
            }
            barWasIdle = isIdle
            // No active composition: whatever opportunity was open was
            // either consumed by a completion hook or abandoned with the
            // erased word — either way the flag must not leak into the
            // next word (metrics).
            wordHadPredictions = false
            // The idle-bar words follow the same capitalization context as
            // real suggestions (start of message, after . ! ?, Caps Lock)
            fallbackSuggestions = fallbackWords.map { displayForm($0, prefix: "", proxy: proxy) }
            unrecognizedTyped = nil
            suggestions = display
            learnedDisplayWords = learnedSet
            return
        }
        barWasIdle = false
        fallbackSuggestions = fallbackWords.map { displayForm($0, prefix: "", proxy: proxy) }
        let previous = previousWord(proxy: proxy)
        let learnedWords = learned?.suggestions(for: prefix, previous: previous) ?? []
        // The dictionary tier is reordered by static context BEFORE it is
        // appended, so context can promote a corpus word among its peers
        // but never above a personally learned one. The two scales are
        // never combined arithmetically — see docs/ARTIFACT_CONTRACT.md §4.
        let dictionaryWords = rankedDictionaryWords(for: prefix, previous: previous)
        var merged = learnedWords
        var seen = Set(merged.map(Self.dedupKey))
        for word in dictionaryWords where seen.insert(Self.dedupKey(word)).inserted {
            merged.append(word)
        }

        var display: [String] = []
        var learnedSet: Set<String> = []
        for (index, word) in merged.prefix(3).enumerated() {
            let form = displayForm(word, prefix: prefix, proxy: proxy)
            display.append(form)
            if index < learnedWords.count { learnedSet.insert(form) }
        }
        // Native-style literal candidate: a typed word unknown to BOTH
        // sources — absent from the bundled dictionary and not a visible
        // learned word (each checked by its own exact lookup with the same
        // normalization as the prefix queries above) — leads the bar
        // exactly as typed, and the view marks it with «…». Recognized
        // words keep the existing behavior untouched.
        if wordDB?.contains(prefix) != true, learned?.isRecognized(prefix) != true {
            unrecognizedTyped = prefix
            suggestions = [prefix] + display.prefix(2)
        } else {
            unrecognizedTyped = nil
            suggestions = display
        }
        learnedDisplayWords = learnedSet
        // Metrics: the composed word has seen at least one predictive
        // candidate (the quoted literal alone does not count) — one
        // opportunity per word, consumed by the completion hooks.
        if !display.isEmpty { wordHadPredictions = true }
    }

    /// Shared display form for every suggestion type — learned, dictionary,
    /// and idle-bar fallback words all go through here.
    ///
    /// The definition's presentation convention for the palochka (Avar:
    /// everything the user SEES carries Ӏ U+04C0 while every stored row is
    /// canonical ӏ U+04CF). One-way and safe: every storage boundary (learn,
    /// lookup, delete, dedup) re-canonicalizes its input, so a round trip
    /// never loses a word.
    private static let text = KeyboardDefinition.current.text

    private static func visiblePalochka(_ word: String) -> String {
        text.visibleForm(word, canonicalPalochka: Normalization.palochka)
    }

    /// A typed prefix dictates its own case (capitalized prefix → capitalized
    /// word, fully uppercase prefix → uppercase word); with no prefix the
    /// sentence context decides (start of message or after `.` `!` `?` →
    /// capitalized, mid-sentence → as stored); Caps Lock always uppercases.
    private func displayForm(_ word: String, prefix: String, proxy: UITextDocumentProxy) -> String {
        let word = Self.visiblePalochka(word)
        if isCapsLock { return word.uppercased() }
        if prefix.isEmpty {
            let autocapitalizes = (proxy.autocapitalizationType ?? .sentences) != .none
            return autocapitalizes && isCursorAtSentenceStart(proxy: proxy)
                ? word.prefix(1).uppercased() + word.dropFirst()
                : word
        }
        guard prefix.first?.isUppercase == true else { return word }
        // Case-neutral letters never vote in the all-caps test (Avar: the
        // palochka, whose typed form Ӏ is category Lu — «ЦӀ» is a
        // capitalized digraph, not an ALL-CAPS prefix). Only the
        // case-bearing letters decide.
        let caseBearing = prefix.filter { !Self.text.caseNeutral.contains($0) }
        let allCaps = caseBearing.count >= 2 && caseBearing == caseBearing.uppercased()
        return allCaps ? word.uppercased()
                       : word.prefix(1).uppercased() + word.dropFirst()
    }

    private static func dedupKey(_ word: String) -> String {
        word.lowercased()
    }

    // MARK: - Local quality metrics (Stage 6)

    /// Whether the word being composed has had at least one predictive
    /// candidate (beyond the quoted literal) on the bar. One opportunity
    /// is counted per completed word, not per suggestion refresh; the
    /// flag resets when the word completes or the composition is
    /// abandoned (prefix back to empty).
    private var wordHadPredictions = false

    /// The word most recently accepted from the bar (with its trailing
    /// space), pending until any other word completes. Going back into it
    /// counts as a correction — event-based, no timeout.
    private var pendingAcceptedWord: String?

    /// Metrics for one manually completed word: every manual completion
    /// counts, and predictive candidates shown during composition close
    /// as one opportunity that was passed over. Completing a word also
    /// settles any pending acceptance as final (the user moved on).
    private func recordManualCompletion() {
        learned?.bumpMetric(.typedManually)
        if wordHadPredictions {
            learned?.bumpMetric(.opportunities)
            learned?.bumpMetric(.ignored)
        }
        wordHadPredictions = false
        pendingAcceptedWord = nil
    }

    /// Metrics line for the DEBUG startup log.
    func metricsLine() -> String {
        learned?.metricsSummary() ?? "no learned store"
    }

    // MARK: - Learning (Stage 1, docs/LOCAL_SUGGESTIONS_ROADMAP.md)

    /// Punctuation that finishes the word before it, like space and return do.
    private static let wordTerminators: Set<String> = [".", ",", "?", "!", ";", ":"]

    /// Punctuation that, typed right after a bar tap, swallows the
    /// auto-inserted trailing space and lands next to the word. The rule
    /// itself is Apple-documented ("if you enter a comma, period, or
    /// other punctuation, the space is deleted"); the exact set is OUR
    /// reading of "other punctuation": sentence marks, clause marks, and
    /// unambiguous closers. Excluding quotes is our design decision, not
    /// verified native behavior — a quote after a space is usually an
    /// OPENING quote for the next word, so the space must stay.
    private static let autoSpaceSwallowers: Set<String> =
        [".", ",", "?", "!", ";", ":", ")", "]", "}"]

    /// Closing wrappers that may trail a sentence ender («word?» / word.)
    /// without hiding it: capitalization and the double-space period look
    /// through them. Our design decision in the native spirit (not
    /// verified against iOS glyph by glyph).
    private static let sentenceClosers: Set<Character> = [")", "]", "}", "\"", "'", "»"]

    /// The word just inserted by a suggestion-bar tap together with its
    /// automatic trailing space — predictive and literal taps alike. Armed
    /// only for the very next key event: any other key or a host resync
    /// clears it, so a manually typed space or a space away from the
    /// cursor can never be swallowed. Deliberately separate from
    /// `pendingAcceptedWord` (metrics), which has different semantics and
    /// lifecycle.
    private var autoSpacedAcceptedWord: String?

    /// Records the word before the cursor as completed, together with the
    /// word preceding it in the same sentence. Called before the terminator
    /// (space / return / punctuation) is inserted; the terminator handlers
    /// clear `lastCompletedWord` again when they end the sentence.
    private func learnCompletedWord(proxy: UITextDocumentProxy) {
        let word = wordPrefix(proxy: proxy)
        guard !word.isEmpty else { return }
        recordManualCompletion()
        learned?.learn(word, previous: previousWord(proxy: proxy), picked: false)
        lastCompletedWord = word
    }

    /// Records a suggestion chosen from the bar — a stronger signal than
    /// typing. `previous` must be captured before the prefix is replaced.
    /// With the trailing space inserted the word is completed and next-word
    /// suggestions chain from it; without it (auto-space setting off) the
    /// word stays the composed prefix the user can keep extending.
    func recordPickedSuggestion(_ word: String, previous: String?, insertedSpace: Bool) {
        learned?.learn(word, previous: previous, picked: true)
        // Metrics: tapping the quoted literal confirms the user's own
        // word — any predictions shown were passed over, so it counts as
        // a manual completion. Tapping a real prediction is an
        // acceptance; it stays pending until another word completes, and
        // going back into it counts as a correction.
        if word == unrecognizedTyped {
            recordManualCompletion()
        } else {
            learned?.bumpMetric(.accepted)
            if wordHadPredictions { learned?.bumpMetric(.opportunities) }
            wordHadPredictions = false
            if insertedSpace { pendingAcceptedWord = word }
        }
        if insertedSpace {
            composedWord = ""
            lastCompletedWord = word
            autoSpacedAcceptedWord = word
        } else {
            composedWord = word
        }
    }

    /// Random dictionary words shown while the bar has no real suggestions —
    /// display forms, capitalized by the same rules as real suggestions.
    @Published var fallbackSuggestions: [String] = []

    /// The raw fallback words as stored in the dictionary.
    private var fallbackWords: [String] = []

    /// Whether the last `updateSuggestions` left the bar in the idle state
    /// (no prefix, no next-word suggestions). A fresh random trio is rolled
    /// only on the transition into idle, never continuously while idle.
    private var barWasIdle = true

    /// Re-rolls the idle-bar words; called once per keyboard appearance.
    /// Mid-session re-rolls happen in `updateSuggestions` whenever the bar
    /// transitions back into the idle state.
    func refreshFallbackSuggestions(proxy: UITextDocumentProxy) {
        guard settings.wordSuggestions else {
            fallbackWords = []
            fallbackSuggestions = []
            return
        }
        fallbackWords = wordDB?.randomWords(3) ?? []
        fallbackSuggestions = fallbackWords.map { displayForm($0, prefix: "", proxy: proxy) }
        barWasIdle = true
    }

    /// Whether this displayed suggestion came from the learned store.
    func isLearnedSuggestion(_ display: String) -> Bool {
        learnedDisplayWords.contains(display)
    }

    /// Removes a learned word chosen from the bar; the bundled dictionary
    /// keeps suggesting its own entries as usual.
    func deleteLearnedWord(_ display: String, proxy: UITextDocumentProxy) {
        learned?.delete(display)
        updateSuggestions(proxy: proxy)
    }

    /// Stage 5: wipes the whole learned store (words and pairs) and
    /// refreshes the bar. Triggered from the settings panel.
    func resetLearnedWords(proxy: UITextDocumentProxy) {
        learned?.reset()
        lastCompletedWord = nil
        updateSuggestions(proxy: proxy)
    }

    /// One pass of the contribution bridge, called when the keyboard is
    /// dismissed — never on the typing path. Compile-time inert while
    /// `Contribution.isEnabled` is false, and even once enabled it still
    /// requires user consent, a writable store, and Full Access before a
    /// single byte reaches the App Group. See ContributionExporter.swift.
    func runContributionBridgeIfEnabled(hasFullAccess: Bool) {
        guard Contribution.isEnabled,
              let bridge = ContributionBridge.productionDirectory(
                  appGroupID: KeyboardDefinition.current.data.appGroupID) else { return }
        learned?.runContributionBridge(at: bridge, hasFullAccess: hasFullAccess)
    }

    // MARK: - Settings panel data

    /// Saved words for the settings dictionary page: genuinely user-added
    /// vocabulary only — words past the learned visibility threshold that
    /// are absent from the bundled dictionary (the same exact lookup the
    /// bar's literal candidate uses). The learning store also keeps records
    /// for dictionary words — frequency and bigram signals — but those are
    /// internal and never listed. The page counter derives from this same
    /// array, so the count and the list cannot disagree. The limit matches
    /// the store's own row cap, so the set is complete.
    func savedWords(limit: Int = 5000) -> [String] {
        (learned?.topWords(limit: limit) ?? [])
            .filter { wordDB?.contains($0) != true }
            .map(Self.visiblePalochka)   // delete re-canonicalizes on the way back
    }

    private static let wordSeparators = KeyboardDefinition.current.text.wordSeparators

    func wordPrefix(proxy: UITextDocumentProxy) -> String {
        guard let ctx = proxy.documentContextBeforeInput, !ctx.isEmpty else { return "" }
        // A trailing separator means the last word is already completed:
        // nothing is being composed, and a suggestion tap must never delete
        // or replace that completed word.
        if let scalar = ctx.unicodeScalars.last, Self.wordSeparators.contains(scalar) { return "" }
        return ctx.components(separatedBy: Self.wordSeparators).last(where: { !$0.isEmpty }) ?? ""
    }

    /// The completed word right before the word being typed, within the same
    /// sentence — bigrams never cross a sentence boundary (`.` `!` `?` or a
    /// new line cut the context first). Uses the same tokenizer as
    /// `wordPrefix`. Returns nil when the host truncates the context short.
    func previousWord(proxy: UITextDocumentProxy) -> String? {
        guard let full = proxy.documentContextBeforeInput, !full.isEmpty else { return nil }
        var ctx = Substring(full)
        if let cut = ctx.lastIndex(where: { ".!?\n".contains($0) }) {
            ctx = ctx[ctx.index(after: cut)...]
        }
        let tokens = ctx.components(separatedBy: Self.wordSeparators).filter { !$0.isEmpty }
        // With a trailing separator the last token is already a completed
        // word; while typing, the last token is the current prefix itself.
        let endsWithSeparator = full.unicodeScalars.last.map(Self.wordSeparators.contains) ?? false
        if endsWithSeparator {
            return tokens.last
        }
        return tokens.count >= 2 ? tokens[tokens.count - 2] : nil
    }

    // MARK: - Key handling

    func handleKey(_ cap: KeyCap, proxy: UITextDocumentProxy) {
        // First keystroke dismisses the keyboard name on the spacebar, like native
        showsKeyboardName = false

        // The auto-space swallow survives non-text keys: page switches,
        // shift, the gear — the user is still "right after the accepted
        // word" while walking to the punctuation on the «123» page (the
        // letters page has none of . , ? !). Only text events consume the
        // flag: a character (including the swallowing mark itself), space,
        // return, backspace. Emoji inserts and cursor moves bypass
        // handleKey, but the context check below (word + space still at
        // the cursor) keeps them safe regardless.
        let autoSpaced = autoSpacedAcceptedWord

        switch cap {

        case .spacer:
            break

        case .character(let s):
            autoSpacedAcceptedWord = nil
            if Self.wordTerminators.contains(s) { learnCompletedWord(proxy: proxy) }
            // Sentence punctuation typed right after a bar tap lands next
            // to the word: the auto-inserted trailing space is removed —
            // but only when it provably is that space (flag armed by the
            // tap AND the context still ends with word + space). This
            // runs after learnCompletedWord, which no-ops on the trailing
            // space, so the accepted word is never learned twice.
            if Self.autoSpaceSwallowers.contains(s),
               let word = autoSpaced,
               proxy.documentContextBeforeInput?.hasSuffix(word + " ") == true {
                proxy.deleteBackward()
            }
            let text = isShifted ? KeyboardLayout.applyCase(s, capsLock: isCapsLock) : s
            proxy.insertText(text)
            if s.count == 1, let scalar = s.unicodeScalars.first,
               Self.wordSeparators.contains(scalar) {
                composedWord = ""
            } else {
                composedWord += text
            }
            // Sentence-ending punctuation cuts the next-word context
            if [".", "?", "!"].contains(s) { lastCompletedWord = nil }
            if shiftState == .once { shiftState = .off }
            // Punctuation on the numbers/symbols pages returns to the letters page,
            // like the native keyboard; sentence-ending marks capitalize the next letter
            if (page == .numbers || page == .symbols),
               [".", ",", "?", "!", "'"].contains(s) {
                page = .letters
                if [".", "?", "!"].contains(s), shiftState != .capsLock {
                    shiftState = .once
                }
            }

        case .space:
            autoSpacedAcceptedWord = nil
            // Quick double space after a word turns into ". " with a capital next
            if settings.doubleSpacePeriod,
               let last = lastSpaceTap, Date().timeIntervalSince(last) < 0.35,
               let before = proxy.documentContextBeforeInput,
               before.hasSuffix(" "), before.count >= 2,
               let prev = before.dropLast().last,
               // The shortcut also fires after a closing quote/bracket —
               // «word" ␣␣» → «word". » (our extension; the letter/digit
               // core is the classic rule)
               prev.isLetter || prev.isNumber || Self.sentenceClosers.contains(prev) {
                proxy.deleteBackward()
                proxy.insertText(". ")
                if shiftState != .capsLock { shiftState = .once }
                lastSpaceTap = nil
                lastCompletedWord = nil  // ". " ends the sentence
            } else {
                learnCompletedWord(proxy: proxy)
                proxy.insertText(" ")
                lastSpaceTap = Date()
            }
            composedWord = ""

        case .return:
            autoSpacedAcceptedWord = nil
            learnCompletedWord(proxy: proxy)
            proxy.insertText("\n")
            composedWord = ""
            lastCompletedWord = nil  // a new line starts a new sentence
            // A new paragraph starts a new sentence, like the native keyboard
            if shiftState != .capsLock,
               (proxy.autocapitalizationType ?? .sentences) != .none {
                shiftState = .once
            }

        case .backspace:
            autoSpacedAcceptedWord = nil
            // Deleting the trailing space of a completed word means "going
            // back to edit that word": composition resumes with the whole
            // word, so the bar switches from next-word predictions straight
            // to suggestions for the full word. The word is extracted from
            // the pre-delete context because the proxy lags behind our own
            // edit. Only this exact transition — a single space with a word
            // character before it — resumes; every other deletion keeps the
            // existing behavior.
            var resumedWord: String?
            if composedWord.isEmpty,
               let ctx = proxy.documentContextBeforeInput, ctx.hasSuffix(" "),
               let prev = ctx.dropLast().unicodeScalars.last,
               !Self.wordSeparators.contains(prev) {
                resumedWord = String(ctx.dropLast())
                    .components(separatedBy: Self.wordSeparators)
                    .last(where: { !$0.isEmpty })
            }
            proxy.deleteBackward()
            if let resumedWord {
                // Metrics: going back into the word just accepted from the
                // bar means the suggestion did not survive contact with
                // the user — a correction, however much time has passed.
                if resumedWord == pendingAcceptedWord {
                    learned?.bumpMetric(.corrected)
                }
                pendingAcceptedWord = nil
                composedWord = resumedWord
            } else if !composedWord.isEmpty {
                composedWord.removeLast()
            }

        case .shift:
            // off → once (single shift) → capsLock (double tap) → off
            switch shiftState {
            case .off:      shiftState = .once
            case .once:     shiftState = .capsLock
            case .capsLock: shiftState = .off
            }

        case .numbers:  page = .numbers
        case .symbols:  page = .symbols
        case .letters:  page = .letters
        case .emoji:    page = .emoji
        case .settings: showsSettings = true
        case .globe:    break
        }
    }

    // MARK: - Auto-capitalization

    /// Re-evaluates the shift state from the field's autocapitalization trait
    /// and the text before the cursor. Called on every text or cursor change;
    /// Caps Lock always wins over the automatic rules.
    func updateShiftFromContext(proxy: UITextDocumentProxy) {
        guard shiftState != .capsLock else { return }
        let type = proxy.autocapitalizationType ?? .sentences
        let shouldShift: Bool
        switch type {
        case .none:
            shouldShift = false
        case .allCharacters:
            shouldShift = true
        case .words:
            let before = proxy.documentContextBeforeInput ?? ""
            shouldShift = before.isEmpty || before.last?.isWhitespace == true
        default:
            shouldShift = isCursorAtSentenceStart(proxy: proxy)
        }
        shiftState = shouldShift ? .once : .off
    }

    /// Sentence start: empty or whitespace-only context, a fresh new line, or
    /// a sentence delimiter as the last non-whitespace character. A trailing
    /// space is not required, matching the native period behavior.
    private func isCursorAtSentenceStart(proxy: UITextDocumentProxy) -> Bool {
        guard let before = proxy.documentContextBeforeInput, !before.isEmpty else { return true }
        if before.last?.isNewline == true { return true }
        // Closing quotes/brackets may trail the sentence ender — «word?» is
        // still a sentence end, so capitalization looks through them
        var trimmed = Substring(before.trimmingCharacters(in: .whitespacesAndNewlines))
        while let last = trimmed.last, Self.sentenceClosers.contains(last) {
            trimmed = trimmed.dropLast()
        }
        guard let last = trimmed.last else { return true }
        return [".", "!", "?"].contains(String(last))
    }

    // MARK: - Cursor line jumps (space trackpad mode)

    /// Moves the cursor to the previous/next `"\n"`-separated line, keeping the
    /// column when the neighbouring line is visible in the document context.
    ///
    /// Many hosts truncate the context at paragraph boundaries, so without a
    /// visible `"\n"` one newline is still crossed blindly: up lands at the end
    /// of the previous line, down at the start of the next (hosts clamp at the
    /// document edges). Visual wraps of long lines are invisible to extensions.
    func moveCursorLine(up: Bool, proxy: UITextDocumentProxy) {
        if up {
            let before = proxy.documentContextBeforeInput ?? ""
            let lines = before.components(separatedBy: "\n")
            let column = lines[lines.count - 1].count
            if lines.count >= 2 {
                let prevLen = lines[lines.count - 2].count
                proxy.adjustTextPosition(byCharacterOffset: -(column + 1 + max(prevLen - column, 0)))
            } else {
                proxy.adjustTextPosition(byCharacterOffset: -(column + 1))
            }
        } else {
            let after = proxy.documentContextAfterInput ?? ""
            let lines = after.components(separatedBy: "\n")
            let restOfCurrent = lines[0].count
            if lines.count >= 2 {
                let nextLen = lines[1].count
                let column = (proxy.documentContextBeforeInput?.components(separatedBy: "\n").last ?? "").count
                proxy.adjustTextPosition(byCharacterOffset: restOfCurrent + 1 + min(column, nextLen))
            } else {
                proxy.adjustTextPosition(byCharacterOffset: restOfCurrent + 1)
            }
        }
    }

    // MARK: - Emoji

    @Published var recentEmojis: [String] =
        UserDefaults.standard.stringArray(forKey: KeyboardModel.recentEmojisKey) ?? []

    private static let recentEmojisKey = "recentEmojis"
    private static let recentEmojisLimit = 24

    func recordRecentEmoji(_ emoji: String) {
        var recents = recentEmojis
        recents.removeAll { $0 == emoji }
        recents.insert(emoji, at: 0)
        if recents.count > Self.recentEmojisLimit {
            recents.removeLast(recents.count - Self.recentEmojisLimit)
        }
        recentEmojis = recents
        UserDefaults.standard.set(recents, forKey: Self.recentEmojisKey)
    }

    // MARK: - Layout

    func rows(needsGlobe: Bool) -> [[KeyCap]] {
        let main: [[KeyCap]]
        switch page {
        case .letters: main = KeyboardLayout.letterRows(style: layoutStyle)
        case .numbers: main = KeyboardLayout.numberRows(style: layoutStyle)
        case .symbols: main = KeyboardLayout.symbolRows(style: layoutStyle)
        case .emoji:   return []
        }
        return main + [bottomRow(needsGlobe: needsGlobe)]
    }

    private func bottomRow(needsGlobe: Bool) -> [KeyCap] {
        switch page {
        case .letters:
            // The gear opens the in-keyboard settings panel
            var row: [KeyCap] = [.numbers, .settings, .emoji]
            if needsGlobe { row.append(.globe) }
            row.append(.space)
            row.append(.return)
            return row
        case .numbers, .symbols:
            var row: [KeyCap] = [.letters]
            if needsGlobe { row.append(.globe) }
            row += [.space, .return]
            return row
        case .emoji:
            return []
        }
    }
}
