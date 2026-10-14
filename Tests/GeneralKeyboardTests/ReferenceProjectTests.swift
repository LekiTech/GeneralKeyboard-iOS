//
//  ReferenceProjectTests.swift
//  GeneralKeyboardTests
//
//  The Reference/ Xcode project is the engine's integration fixture. These
//  tests keep it consistent with ReferenceDefinition without building it:
//  the artifacts it ships are the ones the tests use, its App Group is the
//  definition's, and its extension is a keyboard that never asks for Full
//  Access.
//

import Foundation
import XCTest
import GeneralKeyboard
import GeneralKeyboardReference

final class ReferenceProjectTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.root.appendingPathComponent(path))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    func testShippedArtifactsAreTheTestFixtures() throws {
        let data = ReferenceDefinition.definition.data
        for name in [data.wordsArtifact, data.bigramsArtifact] {
            let shipped = try Data(contentsOf: Self.root
                .appendingPathComponent("Reference/ReferenceKeyboard/\(name).sqlite"))
            let fixture = try Data(contentsOf: Self.root
                .appendingPathComponent("Tests/GeneralKeyboardTests/Fixtures/ReferenceArtifacts/\(name).sqlite"))
            XCTAssertEqual(shipped, fixture, "\(name).sqlite differs between Reference/ and the test fixtures")
        }
    }

    func testBothTargetsUseTheDefinitionsAppGroup() throws {
        let group = ReferenceDefinition.definition.data.appGroupID
        for target in ["ReferenceApp", "ReferenceKeyboard"] {
            let entitlements = try plist("Reference/\(target)/\(target).entitlements")
            XCTAssertEqual(entitlements["com.apple.security.application-groups"] as? [String], [group], target)
        }
    }

    func testExtensionIsAKeyboardWithoutFullAccess() throws {
        let info = try plist("Reference/ReferenceKeyboard/Info.plist")
        let ext = try XCTUnwrap(info["NSExtension"] as? [String: Any])
        XCTAssertEqual(ext["NSExtensionPointIdentifier"] as? String, "com.apple.keyboard-service")
        XCTAssertEqual(ext["NSExtensionPrincipalClass"] as? String, "$(PRODUCT_MODULE_NAME).KeyboardViewController")
        let attributes = try XCTUnwrap(ext["NSExtensionAttributes"] as? [String: Any])
        XCTAssertEqual(attributes["RequestsOpenAccess"] as? Bool, false)
    }

    func testPrincipalClassInstallsTheDefinitionInBothInitializers() throws {
        let source = try String(contentsOf: Self.root
            .appendingPathComponent("Reference/ReferenceKeyboard/KeyboardViewController.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains(": GeneralKeyboardViewController"))
        let installs = source.components(separatedBy: "KeyboardDefinition.install(ReferenceDefinition.definition)").count - 1
        XCTAssertEqual(installs, 2, "install in init(nibName:bundle:) and init?(coder:)")
    }
}
