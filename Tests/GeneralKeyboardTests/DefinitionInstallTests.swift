//
//  DefinitionInstallTests.swift
//  GeneralKeyboardTests
//
//  Regression for the Phase 2 review: iOS creates a new keyboard
//  controller every time the keyboard is shown again in a running
//  extension process. Each one installs the product's definition in its
//  initializer, after the engine has already read it, and the old install
//  asserted, crashing Debug builds when the user switched keyboards and
//  came back. Installing the same definition again must be a no-op; a
//  definition with another id after first use must be rejected and must
//  not replace the one the engine holds.
//

import UIKit
import XCTest
@testable import GeneralKeyboard
import GeneralKeyboardReference

final class DefinitionInstallTests: GKTestCase {

    private var rejections: [String] = []
    private var savedHandler: ((String) -> Void)?

    override func setUp() {
        super.setUp()
        rejections = []
        savedHandler = KeyboardDefinitionRegistry.rejectionHandler
        KeyboardDefinitionRegistry.rejectionHandler = { [unowned self] in self.rejections.append($0) }
        // The state of a running keyboard: the engine has read the definition.
        _ = KeyboardDefinition.current
    }

    override func tearDown() {
        if let savedHandler { KeyboardDefinitionRegistry.rejectionHandler = savedHandler }
        super.tearDown()
    }

    /// A principal class exactly as products write it.
    private final class ProductController: GeneralKeyboardViewController {
        override init(nibName: String?, bundle: Bundle?) {
            KeyboardDefinition.install(ReferenceDefinition.definition)
            super.init(nibName: nibName, bundle: bundle)
        }
        required init?(coder: NSCoder) {
            KeyboardDefinition.install(ReferenceDefinition.definition)
            super.init(coder: coder)
        }
    }

    @MainActor
    func testEveryNewControllerInTheSameProcessInstallsSafely() {
        let controllers = (0..<3).map { _ in ProductController(nibName: nil, bundle: nil) }
        XCTAssertEqual(controllers.count, 3)
        XCTAssertEqual(rejections, [])
        XCTAssertEqual(KeyboardDefinition.current.id, ReferenceDefinition.definition.id)
    }

    func testADefinitionWithAnotherIDIsRejectedAfterUse() {
        KeyboardDefinition.install(ReferenceDefinition.fourRowOnly)
        XCTAssertEqual(rejections.count, 1)
        XCTAssertEqual(KeyboardDefinition.current.id, ReferenceDefinition.definition.id)
        XCTAssertEqual(KeyboardDefinition.current.layout.styles.count, 2)
    }

    func testReferenceDefinitionsHaveDistinctIDs() {
        let ids = [ReferenceDefinition.definition, ReferenceDefinition.fourRowOnly,
                   ReferenceDefinition.threeRowOnly].map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }
}
