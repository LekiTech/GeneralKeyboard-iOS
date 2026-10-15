//
//  KeyPreviewTests.swift
//  GeneralKeyboardTests
//
//  The key preview card's geometry, against measurements of the native
//  iOS 27 Russian keyboard on an iPhone 18 Pro (402 pt wide): a 30 pt key
//  gets a 54 pt card, 64 pt tall, 3.5 pt above the key; an edge key's card
//  stays on screen; a top-row card fits in the room above the key.
//

import UIKit
import XCTest
@testable import GeneralKeyboard

final class KeyPreviewTests: GKTestCase {

    private let screen: CGFloat = 402

    func testMiddleKeyCardIsCenteredAboveTheKey() {
        let key = CGRect(x: 186, y: 152, width: 30, height: 43)
        let card = KeyPreviewCard.frame(keyFrame: key, containerWidth: screen)
        XCTAssertEqual(card.width, 54)
        XCTAssertEqual(card.height, 64)
        XCTAssertEqual(card.midX, key.midX)
        XCTAssertEqual(card.maxY, key.minY - 3.5, accuracy: 0.001)
    }

    func testEdgeKeysKeepTheirCardOnScreen() {
        let left = KeyPreviewCard.frame(keyFrame: CGRect(x: 6, y: 152, width: 30, height: 43),
                                        containerWidth: screen)
        XCTAssertEqual(left.minX, 0)
        let right = KeyPreviewCard.frame(keyFrame: CGRect(x: 366, y: 152, width: 30, height: 43),
                                         containerWidth: screen)
        XCTAssertEqual(right.maxX, screen)
    }

    func testTopRowCardFitsTheRoomAboveTheKey() {
        // First key row of the 3-row style: 44 pt below the keyboard's top
        let key = CGRect(x: 171, y: 44, width: 27, height: 43)
        let card = KeyPreviewCard.frame(keyFrame: key, containerWidth: screen)
        XCTAssertEqual(card.minY, 0)
        XCTAssertEqual(card.height, 40.5, accuracy: 0.001)
        XCTAssertLessThan(KeyPreviewCard.letterSize(cardHeight: card.height), 36)
        XCTAssertGreaterThan(KeyPreviewCard.letterSize(cardHeight: card.height), 28)
    }

    func testFullHeightCardUsesTheNativeLetterSize() {
        XCTAssertEqual(KeyPreviewCard.letterSize(cardHeight: 64), 36)
    }

    func testAShortTapStaysVisibleBrieflyButNeverDelaysTyping() {
        // Visible long enough to reach the screen (native ~40 ms), short
        // enough not to linger behind fast typing.
        XCTAssertGreaterThanOrEqual(KeyboardView.minimumPressVisibility, 0.04)
        XCTAssertLessThanOrEqual(KeyboardView.minimumPressVisibility, 0.1)
    }
}

/// Key label typography measured on the native iOS 27 Russian keyboard:
/// every character label sits on one baseline 6.5 pt below the key's
/// center, upper- and lowercase alike.
final class KeyLabelTypographyTests: GKTestCase {

    private func baselineBelowCenter(_ cap: KeyCap, _ label: String) -> CGFloat {
        let font = UIFont.systemFont(ofSize: KeyboardLayout.fontSize(for: cap, label: label))
        return (font.ascender + font.descender) / 2
            + KeyboardLayout.labelBaselineShift(for: cap, label: label)
    }

    func testCharacterLabelsShareTheNativeBaseline() {
        for (cap, label) in [(KeyCap.character("а"), "а"), (.character("а"), "А"),
                             (.character("кӏ"), "кӏ"), (.character("1"), "1")] {
            XCTAssertEqual(baselineBelowCenter(cap, label), 6.5, accuracy: 0.001, label)
        }
    }

    func testOtherKeysAreNotShifted() {
        for cap in [KeyCap.shift, .backspace, .numbers, .space, .return] {
            XCTAssertEqual(KeyboardLayout.labelBaselineShift(for: cap, label: "x"), 0)
        }
    }
}
