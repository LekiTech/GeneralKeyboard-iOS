//
//  ViewSnapshotTests.swift
//  GeneralKeyboardTests
//
//  Pixel snapshots of the keyboard and the settings panel (Phase 1
//  characterization). They pin every user-visible string, label, icon and
//  geometry the views draw, so moving language data into a
//  KeyboardDefinition can be proven to change nothing on screen.
//
//  References live in Tests/GeneralKeyboardTests/Snapshots/. They were
//  recorded from the released Avar keyboard (AvarKeyboard-iOS de7467d) and
//  must match with the reference definition, whose fixture data is Avar's.
//  To (re)record:
//    TEST_RUNNER_RECORD_SNAPSHOTS=1 xcodebuild test -scheme GeneralKeyboard-Package \
//      -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' \
//      -only-testing:GeneralKeyboardTests/ViewSnapshotTests
//  Recording never passes: it fails each case on purpose so a recorded run
//  cannot be mistaken for a verified one. A mismatch writes the actual
//  image to Snapshots/_failures/.
//
//  Environment notes. Views render inside a window attached to the test
//  runner's scene and are captured with CALayer.render, which (unlike
//  ImageRenderer) draws ScrollView content and toggles. The runner's
//  Bundle.main has no string catalog, so String(localized:) subtitles show
//  their English keys — identically before and after any refactor.
//

import XCTest
import SwiftUI
import UIKit
@testable import GeneralKeyboard
@testable import GeneralKeyboardBridge
import GeneralKeyboardReference

@MainActor
final class ViewSnapshotTests: GKTestCase {

    // MARK: - Keyboard

    func testLettersThreeRow() throws {
        for (name, shift) in [("off", ShiftState.off), ("once", .once), ("capsLock", .capsLock)] {
            let m = freshModel(style: .threeRow) { $0.shiftState = shift }
            try snapshotKeyboard(m, "kb.threeRow.letters.shift-\(name)")
        }
    }

    func testLettersFourRow() throws {
        for (name, shift) in [("off", ShiftState.off), ("once", .once), ("capsLock", .capsLock)] {
            let m = freshModel(style: .fourRow) { $0.shiftState = shift }
            try snapshotKeyboard(m, "kb.fourRow.letters.shift-\(name)")
        }
    }

    func testDarkLetters() throws {
        for style in [LayoutStyle.threeRow, .fourRow] {
            let m = freshModel(style: style) { $0.shiftState = .off }
            try snapshotKeyboard(m, "kb.\(style.rawValue).letters.dark", dark: true)
        }
    }

    func testNumberAndSymbolPages() throws {
        for style in [LayoutStyle.threeRow, .fourRow] {
            for page in [KeyboardPage.numbers, .symbols] {
                let m = freshModel(style: style) { $0.page = page }
                try snapshotKeyboard(m, "kb.\(style.rawValue).\(page)")
            }
        }
    }

    func testEmojiPage() throws {
        for style in [LayoutStyle.threeRow, .fourRow] {
            let m = freshModel(style: style) { $0.page = .emoji }
            try snapshotKeyboard(m, "kb.\(style.rawValue).emoji")
        }
        let dark = freshModel(style: .threeRow) { $0.page = .emoji }
        try snapshotKeyboard(dark, "kb.threeRow.emoji.dark", dark: true)
        // With recents: the title strip reads the native "recents" title and
        // the bar gains the clock icon.
        let recents = freshModel(style: .threeRow, recentEmojis: ["😀", "❤️", "👍"]) {
            $0.page = .emoji
        }
        try snapshotKeyboard(recents, "kb.threeRow.emoji.recents")
    }

    func testGlobeKey() throws {
        let m = freshModel(style: .threeRow) { $0.shiftState = .off; $0.needsGlobe = true }
        try snapshotKeyboard(m, "kb.threeRow.letters.globe")
    }

    func testReturnKeyLabels() throws {
        let types: [(String, UIReturnKeyType)] = [
            ("default", .default), ("go", .go), ("google", .google), ("join", .join),
            ("next", .next), ("route", .route), ("search", .search), ("send", .send),
            ("yahoo", .yahoo), ("done", .done), ("emergencyCall", .emergencyCall),
            ("continue", .continue),
        ]
        for (name, type) in types {
            let m = freshModel(style: .threeRow) { $0.shiftState = .off; $0.returnKeyType = type }
            try snapshotKeyboard(m, "kb.threeRow.return-\(name)")
        }
        // The numbers page shares the bottom row's return key.
        let n = freshModel(style: .fourRow) { $0.page = .numbers; $0.returnKeyType = .send }
        try snapshotKeyboard(n, "kb.fourRow.numbers.return-send")
    }

    func testSpaceBarStates() throws {
        let name = freshModel(style: .threeRow) { $0.shiftState = .off; $0.showsKeyboardName = true }
        try snapshotKeyboard(name, "kb.threeRow.space-keyboardName")
        let noLabel = freshModel(style: .threeRow, settings: .with { $0.spaceLabel = false }) {
            $0.shiftState = .off
        }
        try snapshotKeyboard(noLabel, "kb.threeRow.space-noCornerLabel")
    }

    func testSuggestionBar() throws {
        let m = freshModel(style: .threeRow) {
            $0.shiftState = .off
            $0.suggestions = ["гьабуна", "цӀияб", "рагӀи"]
        }
        try snapshotKeyboard(m, "kb.threeRow.suggestions")
    }

    func testSettingsPanelOverKeyboard() throws {
        for style in [LayoutStyle.threeRow, .fourRow] {
            let m = freshModel(style: style) { $0.showsSettings = true }
            try snapshotKeyboard(m, "kb.\(style.rawValue).settingsHome")
        }
    }

    // MARK: - Settings panel, full height

    func testPanelHome() throws {
        let m = freshModel(style: .threeRow)
        try snapshot(SettingsPanelView(model: m), "panel.home", height: 560)
        try snapshot(SettingsPanelView(model: m), "panel.home.dark", height: 560, dark: true)
        let themed = freshModel(style: .threeRow, settings: .with { $0.theme = .dark })
        try snapshot(SettingsPanelView(model: themed), "panel.home.theme-dark", height: 560)
    }

    // Pages reached through the test-only initial page (the keyboard
    // itself always opens the panel on home).

    func testPanelInputPage() throws {
        let m = freshModel(style: .threeRow)
        try snapshot(SettingsPanelView(model: m, initialPage: .input), "panel.input", height: 1150)
        try snapshot(SettingsPanelView(model: m, initialPage: .input), "panel.input.dark",
                     height: 1150, dark: true)
        let changed = freshModel(style: .fourRow, settings: .with {
            $0.wordSuggestions = false
            $0.spaceLabel = false
            $0.learnSpeed = .conservative
            $0.calloutDelay = .long
        })
        try snapshot(SettingsPanelView(model: changed, initialPage: .input),
                     "panel.input.changed", height: 1150)
    }

    func testPanelThemePage() throws {
        let m = freshModel(style: .threeRow)
        try snapshot(SettingsPanelView(model: m, initialPage: .theme), "panel.theme", height: 400)
        let dark = freshModel(style: .threeRow, settings: .with { $0.theme = .dark })
        try snapshot(SettingsPanelView(model: dark, initialPage: .theme), "panel.theme.dark",
                     height: 400, dark: true)
    }

    func testPanelDictionaryPage() throws {
        let empty = freshModel(style: .threeRow)
        try snapshot(SettingsPanelView(model: empty, initialPage: .dictionary),
                     "panel.dictionary.empty", height: 400)
        // Distinct counts give a deterministic order; the stored palochka is
        // U+04CF and the list must show U+04C0.
        let words = ["цӏияб", "цӏияб", "цӏияб", "гьабуна", "гьабуна", "рагӏи"]
        let learned = freshModel(style: .threeRow, learnedWords: words)
        try snapshot(SettingsPanelView(model: learned, initialPage: .dictionary),
                     "panel.dictionary.words", height: 560)
        let sheet = freshModel(style: .threeRow, learnedWords: words)
        try snapshot(SettingsPanelView(model: sheet, initialPage: .dictionary,
                                       showsDeleteAllSheet: true),
                     "panel.dictionary.deleteAllSheet", height: 560)
        let dark = freshModel(style: .threeRow, learnedWords: words)
        try snapshot(SettingsPanelView(model: dark, initialPage: .dictionary,
                                       showsDeleteAllSheet: true),
                     "panel.dictionary.deleteAllSheet.dark", height: 560, dark: true)
    }

    func testPanelAboutPage() throws {
        let m = freshModel(style: .threeRow)
        try snapshot(SettingsPanelView(model: m, initialPage: .about), "panel.about", height: 400)
        try snapshot(SettingsPanelView(model: m, initialPage: .about), "panel.about.dark",
                     height: 400, dark: true)
    }

    func testSuggestionDeleteConfirmation() throws {
        for (style, dark) in [(LayoutStyle.threeRow, false), (.fourRow, true)] {
            let m = freshModel(style: style) { $0.shiftState = .off }
            let height = KeyboardLayout.metrics(for: style).totalHeight
            try snapshot(KeyboardView(model: m, onKey: { _ in }, pendingDeleteWord: "цӀияб"),
                         "kb.\(style.rawValue).deleteConfirm\(dark ? ".dark" : "")",
                         height: height, dark: dark)
        }
    }

    // MARK: - Harness

    private static let snapshotDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("Snapshots")
    private static let width: CGFloat = 393
    private var recording: Bool { ProcessInfo.processInfo.environment["RECORD_SNAPSHOTS"] == "1" }

    /// The settings panel shows the bundle's marketing version; the test
    /// runner's bundle is not a keyboard's, so the released Avar extension's
    /// value (1.0.0) is fixed here, matching the recorded references.
    nonisolated override func setUp() {
        super.setUp()
        BundleInfo.marketingVersion = "1.0.0"
    }

    func freshModel(style: LayoutStyle,
                    recentEmojis: [String] = [],
                    learnedWords: [String] = [],
                    settings: KeyboardSettings? = nil,
                    configure: (KeyboardModel) -> Void = { _ in }) -> KeyboardModel {
        KeyboardTestEnvironment.freshModel(style: style, recentEmojis: recentEmojis,
                                           learnedWords: learnedWords, settings: settings,
                                           configure: configure)
    }

    private func snapshotKeyboard(_ model: KeyboardModel, _ name: String, dark: Bool = false,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        let height = KeyboardLayout.metrics(for: model.layoutStyle).totalHeight
        try snapshot(KeyboardView(model: model, onKey: { _ in }), name,
                     height: height, dark: dark, file: file, line: line)
    }

    func snapshot(_ view: some View, _ name: String, height: CGFloat, dark: Bool = false,
                  file: StaticString = #filePath, line: UInt = #line) throws {
        let image = render(view, height: height, dark: dark)
        let png = try XCTUnwrap(image.pngData(), file: file, line: line)
        let reference = Self.snapshotDirectory.appendingPathComponent("\(name).png")
        if recording {
            try FileManager.default.createDirectory(at: Self.snapshotDirectory,
                                                    withIntermediateDirectories: true)
            try png.write(to: reference)
            XCTFail("Recorded \(name); re-run without RECORD_SNAPSHOTS to verify", file: file, line: line)
            return
        }
        guard let expectedData = try? Data(contentsOf: reference),
              let expected = UIImage(data: expectedData) else {
            XCTFail("Missing reference \(name).png", file: file, line: line)
            return
        }
        let diff = Self.differingPixels(expected, image)
        if diff != 0 {
            let failures = Self.snapshotDirectory.appendingPathComponent("_failures")
            try? FileManager.default.createDirectory(at: failures, withIntermediateDirectories: true)
            try? png.write(to: failures.appendingPathComponent("\(name).png"))
            XCTFail("\(name): \(diff) pixels differ from the reference", file: file, line: line)
        }
    }

    private func render(_ view: some View, height: CGFloat, dark: Bool) -> UIImage {
        let size = CGSize(width: Self.width, height: height)
        let host = UIHostingController(rootView: AnyView(view.frame(width: size.width,
                                                                     height: size.height)))
        host.safeAreaRegions = []
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        for _ in 0..<8 {
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            host.view.layer.render(in: ctx.cgContext)
        }
        window.isHidden = true
        window.rootViewController = nil
        return image
    }

    /// Exact RGBA comparison of two images at the same pixel size.
    private static func differingPixels(_ a: UIImage, _ b: UIImage) -> Int {
        guard let ra = rgba(a), let rb = rgba(b), ra.width == rb.width,
              ra.height == rb.height else { return Int.max }
        if ra.bytes == rb.bytes { return 0 }
        var count = 0
        for i in stride(from: 0, to: ra.bytes.count, by: 4)
        where ra.bytes[i..<i + 4] != rb.bytes[i..<i + 4] {
            count += 1
        }
        return count
    }

    private static func rgba(_ image: UIImage) -> (bytes: [UInt8], width: Int, height: Int)? {
        guard let cg = image.cgImage else { return nil }
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &bytes, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        return (bytes, w, h)
    }
}

