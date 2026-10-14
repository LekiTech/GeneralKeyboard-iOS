//
//  Normalization.swift
//  GeneralKeyboard
//
//  The canonical form of a token — one definition for the bundled
//  dictionary, the static bigrams, learned words, learned bigrams, future
//  contribution batches, and future server processing. A word must be the
//  same word in all six places or none of them can be joined.
//
//  The pipeline and every engine-contract gate live here; the script and
//  language data (palochka, lookalikes, homoglyphs, digraph tails) come
//  from the keyboard's NormalizationProfile (NormalizationProfile.swift).
//
//  This is the runtime half of a contract whose other half is
//  `normalize()` in scripts/build_dictionaries.py. The two MUST change
//  together, and any change bumps NORMALIZATION_VERSION and forces both
//  artifacts to be rebuilt. See docs/ARTIFACT_CONTRACT.md §2.
//

import Foundation

enum Normalization {

    /// The current keyboard's profile, read once per process.
    static let profile: NormalizationProfile = KeyboardDefinition.current.normalization

    /// Bumped when the rules change. Artifacts record the version they were
    /// built with, so a mismatch is detectable rather than silent.
    static var version: Int { profile.version }

    /// The canonical palochka (U+04CF for Dagestanian Cyrillic).
    static var palochka: Character? { profile.palochka }

    /// A digraph tail extends the previous letter instead of counting as its
    /// own, so "цӏ" and "къ" are ONE letter. Declared by the profile; the
    /// definition tests check it covers every two-character callout.
    static let digraphTails: Set<Character> = profile.digraphTails

    private static let repairScripts = profile.repairScripts
    private static let palochkaLookalikes = profile.palochkaLookalikes
    private static let homoglyphs = profile.homoglyphs

    private static func needsRepair(_ token: String) -> Bool {
        token.unicodeScalars.contains { scalar in
            repairScripts.contains { $0.contains(scalar.value) }
        }
    }

    /// The canonical form. Idempotent by construction:
    /// `canonical(canonical(x)) == canonical(x)`.
    static func canonical(_ token: String) -> String {
        // 1. NFC, so a decomposed «й» (и + combining breve) is the same word
        //    as the precomposed U+0439.
        var result = token.precomposedStringWithCanonicalMapping
        // 2. Trim. Internal whitespace makes a token invalid, not repairable.
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // 3. Lowercase — this alone maps Ӏ (U+04C0) to ӏ (U+04CF).
        result = result.lowercased()
        // 4-5. Repair lookalikes, but only where the token is in a repair
        //      script (Cyrillic for the built-in profile).
        if needsRepair(result) {
            let palochka = profile.palochka
            result = String(result.map { ch in
                if let palochka, palochkaLookalikes.contains(ch) { return palochka }
                return homoglyphs[ch] ?? ch
            })
        }
        // 6. NFC again so the function is idempotent whatever the repairs did.
        return result.precomposedStringWithCanonicalMapping
    }

    /// Whether a token is ALREADY in canonical form, compared by scalars.
    ///
    /// Swift's `==` is canonical-equivalent, so `decomposed == precomposed`
    /// is true even though SQLite — which compares bytes — treats them as
    /// two different rows. Any code deciding whether a stored value needs
    /// rewriting must use this, not `==`.
    static func isCanonical(_ token: String) -> Bool {
        Array(canonical(token).unicodeScalars) == Array(token.unicodeScalars)
    }

    /// Letters in a canonical token, digraphs counted as one.
    static func letterCount(_ token: String) -> Int {
        token.reduce(0) { digraphTails.contains($1) ? $0 : $0 + 1 }
    }

    /// Whether a canonical token may be stored, learned, or contributed.
    ///
    /// This is the CONTRACT definition. It is intentionally not wired into
    /// the released learning path yet: `LearnedWords.isLearnable` keeps its
    /// own equivalent rules, and unifying them changes what gets learned,
    /// which needs its own migration and review.
    static func isValidToken(_ token: String) -> Bool {
        // Scalars, not Characters: Python's len() counts code points, and
        // the two halves of the contract must measure length identically.
        // On canonical (NFC) Cyrillic text the two counts agree anyway; they
        // diverge only on combining-mark sequences, exactly where an
        // implicit disagreement would hide.
        guard !token.isEmpty, token.unicodeScalars.count <= 64 else { return false }
        guard !token.contains(where: \.isWhitespace) else { return false }
        guard !token.contains(where: \.isNumber) else { return false }
        guard !token.contains("@"), !token.contains("/"), !token.contains(".") else { return false }
        if profile.rejectsASCIILetters {
            guard !token.contains(where: { $0.isASCII && $0.isLetter }) else { return false }
        }
        // No control or format characters. Controls (Cc) include U+001F,
        // which the contribution outbox uses to join bigram keys — a token
        // that could carry it would make that encoding ambiguous. Formats
        // (Cf) are the invisibles — ZWJ, ZWNJ, bidi marks — that would let
        // two identical-looking tokens be different rows.
        guard !token.unicodeScalars.contains(where: { scalar in
            let category = scalar.properties.generalCategory
            return category == .control || category == .format
        }) else { return false }
        return letterCount(token) >= 2
    }
}
