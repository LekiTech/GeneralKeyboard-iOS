//
//  KeyboardGeometry.swift
//  GeneralKeyboard
//
//  The live geometry of the keyboard for the device and orientation it is
//  shown in. A definition's metrics describe the iPhone portrait keyboard
//  (key height, row spacing, emoji grid); every other size class scales
//  them with the proportions of Apple's own keyboard, measured on iOS 27.
//  Row counts come from the layout style, so a 4-row style stays one row
//  taller than a 3-row style in every size class.
//

import UIKit

/// Where the keyboard is shown. iPad floating and narrow multitasking
/// keyboards (compact width) use the iPhone geometry, as the system does.
public enum KeyboardSizeClass: Equatable, Sendable {
    case phonePortrait
    case phoneLandscape
    case padPortrait
    case padLandscape

    /// The size class for an input view controller's traits and the screen
    /// it is shown on.
    static func current(traits: UITraitCollection, screenSize: CGSize) -> KeyboardSizeClass {
        let landscape = screenSize.width > screenSize.height
        if traits.userInterfaceIdiom == .pad, traits.horizontalSizeClass != .compact {
            return landscape ? .padLandscape : .padPortrait
        }
        return traits.verticalSizeClass == .compact || landscape ? .phoneLandscape : .phonePortrait
    }

    var isPad: Bool { self == .padPortrait || self == .padLandscape }
}

public struct KeyboardGeometry: Equatable, Sendable {
    /// Suggestion bar height and the gap below it.
    public var barHeight: CGFloat
    public var barGap: CGFloat
    public var keyHeight: CGFloat
    public var rowSpacing: CGFloat
    /// Horizontal gap between keys and the inset of the rows from the
    /// keyboard's left and right edges.
    public var keyGap: CGFloat
    public var sideInset: CGFloat
    /// Space below the bottom row (iPad keyboards sit higher than the
    /// frame the system gives an extension).
    public var bottomInset: CGFloat
    public var cornerRadius: CGFloat
    /// Key label size relative to the iPhone portrait labels.
    public var labelScale: CGFloat
    /// Whether pressing a character key shows the preview card (iPad
    /// keyboards have none).
    public var showsKeyPreview: Bool
    public var emojiRows: Int
    public var emojiCellHeight: CGFloat
    public var emojiFontSize: CGFloat
    public var emojiCellWidth: CGFloat
    /// Rows including the bottom row.
    public var rows: Int

    public var totalHeight: CGFloat {
        barHeight + barGap + CGFloat(rows) * keyHeight + CGFloat(rows - 1) * rowSpacing
            + bottomInset + 1
    }

    /// Fixed parts of the emoji page around the grid: title strip, grid top
    /// padding, category bar and its bottom padding.
    static let emojiChrome: CGFloat = 24 + 4 + 40 + 1

    /// Native proportions per size class, as ratios of the iPhone portrait
    /// keyboard (43 pt keys, 11 pt row gaps).
    private struct Native {
        var keyScale: CGFloat
        var rowSpacingScale: CGFloat
        var barHeight: CGFloat
        var barGap: CGFloat
        var keyGap: CGFloat
        var sideInset: CGFloat
        var bottomInset: CGFloat = 0
        var cornerRadius: CGFloat
        var labelScale: CGFloat
        var minEmojiCell: CGFloat
        var emojiScale: CGFloat
        var showsKeyPreview: Bool
    }

    private static func native(_ sizeClass: KeyboardSizeClass) -> Native {
        switch sizeClass {
        case .phonePortrait:
            // 43 × 11 rows. The system pads 15 pt above an extension's view
            // in portrait, so a 32 pt bar + 4 pt gap puts the first row
            // 51 pt below the keyboard's top edge, like native (50.7).
            return Native(keyScale: 1, rowSpacingScale: 1, barHeight: 32, barGap: 4,
                          keyGap: 6, sideInset: 6, cornerRadius: 8, labelScale: 1,
                          minEmojiCell: 33, emojiScale: 1, showsKeyPreview: true)
        case .phoneLandscape:
            // Native: 32 pt keys, 8 pt row gaps, first row 50 pt below the
            // keyboard top (no system padding in landscape), labels ~0.88.
            return Native(keyScale: 32.0 / 43, rowSpacingScale: 8.0 / 11, barHeight: 46, barGap: 4,
                          keyGap: 6, sideInset: 6, cornerRadius: 7.5, labelScale: 0.88,
                          minEmojiCell: 36, emojiScale: 1, showsKeyPreview: true)
        case .padPortrait:
            // Native iPad 11" portrait: 50 x 55.5 pt keys, 10 pt between
            // keys, 9 pt between rows, rows 9 pt from the edges, first row
            // 50.5 pt below the keyboard top, last row 28 pt above the
            // screen bottom (inferred 7 pt above an extension frame's end,
            // like landscape), letters ~0.95 of the iPhone size, no key
            // preview popups.
            return Native(keyScale: 55.5 / 43, rowSpacingScale: 9.0 / 11, barHeight: 42, barGap: 4,
                          keyGap: 10, sideInset: 9, bottomInset: 7, cornerRadius: 9, labelScale: 0.95,
                          minEmojiCell: 44, emojiScale: 1.25, showsKeyPreview: false)
        case .padLandscape:
            // Native iPad 11" landscape: 72.5 x 73.5 pt keys, 14 pt between
            // keys, 12 pt between rows, rows 15 pt from the edges, first row
            // 56 pt below the keyboard top, last row 30.5 pt above the screen
            // bottom (9.5 pt higher than an extension's frame ends), letters
            // ~1.18. The system's own shortcut bar (undo, redo, paste) sits
            // above a third-party keyboard on iPad, so our suggestion bar is
            // kept compact.
            return Native(keyScale: 73.5 / 43, rowSpacingScale: 12.0 / 11, barHeight: 42, barGap: 4,
                          keyGap: 14, sideInset: 15, bottomInset: 9.5, cornerRadius: 11, labelScale: 1.18,
                          minEmojiCell: 56, emojiScale: 1.5, showsKeyPreview: false)
        }
    }

    /// The geometry for a layout style in a size class. `metrics` are the
    /// definition's iPhone portrait metrics for the style.
    static func make(metrics: KeyboardLayout.Metrics, rows: Int,
                     sizeClass: KeyboardSizeClass) -> KeyboardGeometry {
        let n = native(sizeClass)
        var g = KeyboardGeometry(
            barHeight: n.barHeight, barGap: n.barGap,
            keyHeight: (metrics.keyHeight * n.keyScale).rounded(),
            rowSpacing: (metrics.rowSpacing * n.rowSpacingScale).rounded(),
            keyGap: n.keyGap, sideInset: n.sideInset, bottomInset: n.bottomInset,
            cornerRadius: n.cornerRadius,
            labelScale: n.labelScale, showsKeyPreview: n.showsKeyPreview,
            emojiRows: metrics.emojiRows, emojiCellHeight: metrics.emojiCellHeight,
            emojiFontSize: (32 * n.emojiScale).rounded(),
            emojiCellWidth: (44 * n.emojiScale).rounded(),
            rows: rows)
        if sizeClass != .phonePortrait {
            // As many rows as fit at a comfortable cell height, sharing the
            // grid height evenly.
            let grid = g.totalHeight - emojiChrome
            let count = max(2, Int((grid + 2) / (n.minEmojiCell + 2)))
            g.emojiRows = count
            g.emojiCellHeight = ((grid - CGFloat(count - 1) * 2) / CGFloat(count)).rounded(.down)
        }
        return g
    }
}

extension KeyboardLayout {
    /// The live geometry of a style in a size class.
    static func geometry(for style: LayoutStyle, sizeClass: KeyboardSizeClass) -> KeyboardGeometry {
        let spec = KeyboardDefinition.current.layout.spec(for: style)
        return KeyboardGeometry.make(metrics: spec.metrics, rows: spec.letterRows.count + 1,
                                     sizeClass: sizeClass)
    }
}
