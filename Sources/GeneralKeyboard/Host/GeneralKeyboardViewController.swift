//
//  GeneralKeyboardViewController.swift
//  GeneralKeyboard
//
//  Created by Enver Eskendarov on 6/28/26.
//

import UIKit
import SwiftUI
import Combine
import os.log

/// UIKit bridge for the keyboard extension: hosts the SwiftUI keyboard,
/// owns `textDocumentProxy`, wires the view's closures into `KeyboardModel`,
/// and forwards `textDidChange` so the model can resync with the host app.
/// Never present UIKit view controllers (alerts) from here — the restricted
/// extension environment kills the keyboard.
///
/// A product's principal class subclasses this and installs its
/// KeyboardDefinition in both initializers BEFORE calling super (the model
/// is created during super.init); see KeyboardDefinition.swift.
open class GeneralKeyboardViewController: UIInputViewController {

    private var model = KeyboardModel()

    public override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
        super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    private var hideKeyboardNameWork: DispatchWorkItem?
    private var themeCancellable: AnyCancellable?
    private var layoutStyleCancellable: AnyCancellable?
    private var heightConstraint: NSLayoutConstraint?
    #if DEBUG
    /// Phase 1B: samples memory around the page transitions that matter
    /// (letters ⇄ emoji). Compiled out of Release together with MemoryProbe.
    private var memoryProbeCancellable: AnyCancellable?
    #endif

    open override func viewDidLoad() {
        super.viewDidLoad()
        setupKeyboard()
        #if DEBUG
        MemoryProbe.log("viewDidLoad")
        memoryProbeCancellable = model.$page
            .removeDuplicates()
            .sink { page in
                // One sample per page switch, never per keystroke. The
                // emoji grid renders lazily, so the interesting number is
                // how much of the CoreText glyph cache survives coming
                // back to the letters page.
                DispatchQueue.main.async { MemoryProbe.log("page=\(page)") }
            }
        #endif
        #if DEBUG
        // Local quality metrics baseline (Stage 6): visible in Console.app,
        // category "kb-metrics". Debug builds only; nothing is transmitted.
        Logger(subsystem: Bundle.main.bundleIdentifier
            ?? KeyboardDefinition.current.data.diagnosticsSubsystem,
               category: "kb-metrics")
            .log("[kb-metrics] \(self.model.metricsLine(), privacy: .public)")
        #endif
        // The theme applies through UIKit so every dynamicProvider color
        // re-resolves in place: switching in the panel recolors the whole
        // keyboard live, no reopening. @Published emits the current value
        // on subscription, so the saved theme also applies right here.
        themeCancellable = model.$settings
            .map(\.theme)
            .removeDuplicates()
            .sink { [weak self] theme in
                guard let self else { return }
                self.view.overrideUserInterfaceStyle = Self.interfaceStyle(for: theme)
                // The system draws the keyboard backdrop BEHIND our
                // transparent root and it follows the host's theme, not the
                // override — so a forced theme needs its own opaque
                // background in the native backdrop colors. `.system`
                // restores the transparent root (native blurred backdrop).
                self.view.backgroundColor = theme == .system ? .clear : Self.keyboardBackground
            }
    }

    private static func interfaceStyle(for theme: KeyboardSettings.Theme) -> UIUserInterfaceStyle {
        switch theme {
        case .system: return .unspecified
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    /// Flat stand-ins for the system keyboard backdrop, resolved through
    /// the overridden trait (light ≈ #D1D3D9, dark ≈ #2B2B2B).
    private static let keyboardBackground = UIColor { t in
        t.userInterfaceStyle == .dark
            ? UIColor(red: 0.169, green: 0.169, blue: 0.169, alpha: 1)
            : UIColor(red: 0.820, green: 0.827, blue: 0.851, alpha: 1)
    }

    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        model.refreshFallbackSuggestions(proxy: textDocumentProxy)
        model.showsKeyboardName = true
        hideKeyboardNameWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.model.showsKeyboardName = false
        }
        hideKeyboardNameWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Inert until the contribution feature flag ever ships enabled;
        // placed at dismissal so it can never sit on the typing path.
        model.runContributionBridgeIfEnabled(hasFullAccess: hasFullAccess)
    }

    open override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        model.needsGlobe = needsInputModeSwitchKey
        model.returnKeyType = textDocumentProxy.returnKeyType ?? .default
    }

    open override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        model.returnKeyType = textDocumentProxy.returnKeyType ?? .default
        model.syncComposedWord(proxy: textDocumentProxy)
        model.updateShiftFromContext(proxy: textDocumentProxy)
        model.updateSuggestions(proxy: textDocumentProxy)
    }


    private func setupKeyboard() {
        let hc = UIHostingController(rootView: makeKeyboardView())
        addChild(hc)
        view.addSubview(hc.view)
        hc.didMove(toParent: self)

        hc.view.translatesAutoresizingMaskIntoConstraints = false
        hc.view.backgroundColor = .clear
        hc.view.clipsToBounds = false   // allow key preview bubble to appear above keyboard
        hc.view.insetsLayoutMarginsFromSafeArea = false
        view.clipsToBounds = false

        NSLayoutConstraint.activate([
            hc.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hc.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hc.view.topAnchor.constraint(equalTo: view.topAnchor),
            hc.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        // Height follows the layout style: the 3-row grid keeps the
        // original 250, the 4-row grid grows so its extra digraph row
        // never compresses the familiar keys. @Published emits the
        // persisted style on subscription, so the saved choice applies
        // right here on open.
        let h = view.heightAnchor.constraint(
            equalToConstant: KeyboardLayout.metrics(for: model.layoutStyle).totalHeight)
        h.priority = UILayoutPriority(999)
        h.isActive = true
        heightConstraint = h
        layoutStyleCancellable = model.$layoutStyle
            .removeDuplicates()
            .sink { [weak self] style in
                self?.heightConstraint?.constant =
                    KeyboardLayout.metrics(for: style).totalHeight
            }
    }

    open override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        additionalSafeAreaInsets = UIEdgeInsets(
            top: -view.safeAreaInsets.top,
            left: -view.safeAreaInsets.left,
            bottom: -view.safeAreaInsets.bottom,
            right: -view.safeAreaInsets.right
        )
    }

    private func makeKeyboardView() -> KeyboardView {
        KeyboardView(
            model: model,
            onKey: { [weak self] cap in
                guard let self else { return }
                if cap == .globe { self.advanceToNextInputMode(); return }
                self.model.handleKey(cap, proxy: self.textDocumentProxy)
                if cap == .backspace {
                    self.model.updateShiftFromContext(proxy: self.textDocumentProxy)
                }
                self.model.updateSuggestions(proxy: self.textDocumentProxy)
            },
            onSuggestion: { [weak self] word in
                guard let self else { return }
                // The proxy context can lag behind fast typing, so the typed
                // prefix length comes from whichever source saw more: the
                // context or the locally tracked composed word.
                let prefix = self.model.wordPrefix(proxy: self.textDocumentProxy)
                let previous = self.model.previousWord(proxy: self.textDocumentProxy)
                let deleteCount = max(prefix.count, self.model.composedWord.count)
                for _ in 0..<deleteCount { self.textDocumentProxy.deleteBackward() }
                let addsSpace = self.model.settings.autoSpaceAfterSuggestion
                self.textDocumentProxy.insertText(addsSpace ? word + " " : word)
                self.model.recordPickedSuggestion(word, previous: previous,
                                                  insertedSpace: addsSpace)
                if self.model.shiftState == .once { self.model.shiftState = .off }
                // Hosts do not send textDidChange for the keyboard's own
                // edits, so refresh here: composedWord is already cleared,
                // which chains straight into next-word suggestions for the
                // accepted word (the stale context cannot resurface it —
                // the prefix comes from composedWord, not the proxy).
                self.model.updateSuggestions(proxy: self.textDocumentProxy)
            },
            onSuggestionDelete: { [weak self] word in
                guard let self else { return }
                self.model.deleteLearnedWord(word, proxy: self.textDocumentProxy)
            },
            onLearnedReset: { [weak self] in
                guard let self else { return }
                self.model.resetLearnedWords(proxy: self.textDocumentProxy)
            },
            onEmojiInsert: { [weak self] emoji in
                guard let self else { return }
                self.textDocumentProxy.insertText(emoji)
                self.model.recordRecentEmoji(emoji)
            },
            onCursorMove: { [weak self] offset in
                self?.textDocumentProxy.adjustTextPosition(byCharacterOffset: offset)
            },
            onCursorLineMove: { [weak self] lines in
                guard let self else { return }
                for _ in 0..<abs(lines) {
                    self.model.moveCursorLine(up: lines < 0, proxy: self.textDocumentProxy)
                }
            }
        )
    }
}
