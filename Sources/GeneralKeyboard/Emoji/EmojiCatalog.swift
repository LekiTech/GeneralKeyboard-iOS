//
//  EmojiCatalog.swift
//  GeneralKeyboard
//
//  The public face of the generated emoji catalog (EmojiData.swift): the
//  stable category ids a product keys its native section titles by
//  (`KeyboardDefinition.emojiCategoryTitles`).
//

public enum EmojiCatalog {
    /// Category ids in catalog order: smileys, nature, food, activity,
    /// travel, objects, symbols, flags.
    public static var categoryIDs: [String] { EmojiData.categories.map(\.id) }
}
