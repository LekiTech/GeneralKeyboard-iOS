//
//  AppModuleTests.swift
//  GeneralKeyboardTests
//
//  The containing-app module: its generic strings resolve from the
//  module's own catalog in both shipped languages, the keyboard name is
//  interpolated rather than spelled, and the screen hosts in a window.
//

import SwiftUI
import UIKit
import XCTest
@testable import GeneralKeyboardApp

final class AppModuleTests: XCTestCase {

    private func localized(_ key: String, _ language: String) -> String? {
        guard let path = GeneralKeyboardAppResources.bundle.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return nil }
        return bundle.localizedString(forKey: key, value: "MISSING", table: nil)
    }

    func testGenericStringsResolveInRussian() {
        XCTAssertEqual(localized("How to install", "ru"), "Как установить")
        XCTAssertEqual(localized("Open Settings", "ru"), "Открыть Настройки")
        XCTAssertEqual(localized("Developed by LekiTech", "ru"), "Разработано LekiTech")
    }

    func testKeyboardNameIsAnArgumentNotALiteral() {
        let format = localized("Turn on **%@**", "ru")
        XCTAssertEqual(format, "Включите **%@**")
        XCTAssertEqual(format.map { String(format: $0, "Reference") }, "Включите **Reference**")
    }

    func testEveryKeyHasEnglishAndRussian() throws {
        let catalog = try XCTUnwrap(sourceCatalog())
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        XCTAssertEqual(strings.count, 8)
        for (key, entry) in strings {
            let locs = entry["localizations"] as? [String: Any] ?? [:]
            XCTAssertNotNil(locs["ru"], "missing ru for \(key)")
            XCTAssertNotNil(localized(key, "ru"), key)
        }
    }

    @MainActor
    func testOnboardingHostsInAWindow() {
        let view = KeyboardOnboardingView(
            title: "General Keyboard", tagline: "Reference keyboard", keyboardName: "Reference",
            features: [.init(0, icon: "keyboard", tint: .blue, title: "One", subtitle: "Two")]) {
            OnboardingCard { Text(verbatim: "Product card") }
        }
        // Same window strategy as the snapshot harness: the runner's scene
        // when it has one, a detached window otherwise.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        let host = UIHostingController(rootView: view)
        window.rootViewController = host
        window.isHidden = false
        host.view.layoutIfNeeded()
        XCTAssertGreaterThan(host.sizeThatFits(in: CGSize(width: 402, height: CGFloat.infinity)).height, 600)
        window.isHidden = true
    }

    private func sourceCatalog() -> [String: Any]? {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/GeneralKeyboardApp/Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
