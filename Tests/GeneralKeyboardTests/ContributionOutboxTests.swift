//
//  ContributionOutboxTests.swift
//
//  The contribution queue is inert in shipping builds, so these tests are
//  the only thing exercising it. They pin the two properties that matter
//  most: that nothing is collected without both the flag and consent, and
//  that what IS collected is an aggregate — bounded, countable, and
//  incapable of holding text.
//

import XCTest
import SQLite3
@testable import GeneralKeyboard
@testable import GeneralKeyboardBridge
import GeneralKeyboardReference

final class ContributionOutboxTests: GKTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("outbox-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() throws -> LearnedWords {
        try XCTUnwrap(LearnedWords(directory: dir))
    }

    private func at(_ daysAgo: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 - Double(daysAgo) * 86_400)
    }

    /// Distinct, contract-valid tokens for capacity tests — digits
    /// would be refused at the door, so distinctness comes from letters.
    private func distinctKey(_ i: Int) -> String {
        let letters = ["а", "б", "в", "г", "д", "е", "ж", "з", "и", "к"]
        return "гаф" + letters[i % 10] + letters[(i / 10) % 10]
            + letters[(i / 100) % 10] + letters[(i / 1000) % 10]
    }

    // MARK: - The gate

    func testContributionIsDisabledInShippingBuilds() {
        XCTAssertFalse(Contribution.isEnabled,
                       "The flag must ship OFF. If this fails, a build is collecting.")
    }

    func testConsentDefaultsToFalseOnAFreshDatabase() throws {
        let store = try makeStore()
        XCTAssertFalse(store.hasContributionConsent)
        XCTAssertFalse(store.isContributionActive)
    }

    func testConsentDefaultsToFalseOnAnUpgradedProductionDatabase() throws {
        // A database that predates the consent column never agreed to
        // anything; the upgrade must not invent an agreement.
        let store = try makeStore()
        store.learn("кӏвал", previous: nil, picked: false)
        XCTAssertFalse(store.hasContributionConsent)
    }

    func testRecordingIsANoOpWhileTheFlagIsOff() throws {
        let store = try makeStore()
        store.setContributionConsent(true)   // consent alone must not be enough
        for _ in 0..<50 {
            store.recordContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 1)
        }
        XCTAssertEqual(store.pendingContributionCount, 0,
                       "Consent without the flag collects nothing")
    }

    func testRecordingIsANoOpWithoutConsent() throws {
        let store = try makeStore()
        XCTAssertFalse(store.hasContributionConsent)
        store.recordContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 1)
        XCTAssertEqual(store.pendingContributionCount, 0)
    }

    func testClaimingIsANoOpWhileTheGateIsClosed() throws {
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 1)
        XCTAssertEqual(store.pendingContributionCount, 1, "Precondition: something to claim")
        XCTAssertNil(store.claimContributionBatch(),
                     "The gated entry point must refuse while the flag is off")
    }

    // MARK: - No historical backfill

    func testGrantingConsentDoesNotSweepInExistingLearnedData() throws {
        let store = try makeStore()
        for word in ["кӏвал", "хайи", "къуьл"] {
            store.learn(word, previous: "ва", picked: false)
        }
        XCTAssertTrue(store.isRecognized("кӏвал"), "Precondition: there IS history")

        store.setContributionConsent(true)

        XCTAssertEqual(store.pendingContributionCount, 0,
                       "Consent starts collection; it does not retroactively authorize it")
    }

    func testWithdrawingConsentEmptiesTheQueueIncludingClaimedRows() throws {
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 1)
        store.enqueueContribution(kind: .wordDelta, key: "хайи", typedDelta: 1)
        let batch = try XCTUnwrap(store.claimBatch(limit: 1))
        XCTAssertEqual(store.contributionBatch(batch).count, 1)

        store.setContributionConsent(false)

        XCTAssertEqual(store.pendingContributionCount, 0)
        XCTAssertTrue(store.contributionBatch(batch).isEmpty,
                      "An in-flight batch is not a reason to keep data after withdrawal")
    }

    // MARK: - Aggregation

    func testRepeatedEventsCollapseIntoOneRow() throws {
        let store = try makeStore()
        for _ in 0..<100 {
            store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 1)
        }
        XCTAssertEqual(store.pendingContributionCount, 1,
                       "100 events, 1 row — the queue counts words, not keystrokes")

        let batch = try XCTUnwrap(store.claimBatch())
        let rows = store.contributionBatch(batch)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].typed, 100)
        XCTAssertEqual(rows[0].confirmations, 100)
    }

    func testTypedAndPickedAccumulateSeparately() throws {
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 1)
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 1)
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", pickedDelta: 1)

        let rows = store.contributionBatch(try XCTUnwrap(store.claimBatch()))
        XCTAssertEqual(rows[0].typed, 2)
        XCTAssertEqual(rows[0].picked, 1)
    }

    func testDifferentKindsOfTheSameKeyStaySeparateRows() throws {
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 1)
        store.enqueueContribution(kind: .candidate, key: "кӏвал", typedDelta: 1)
        XCTAssertEqual(store.pendingContributionCount, 2,
                       "(kind, key) is the aggregation key, not key alone")
    }

    func testBigramKeyRoundTripsBothHalves() throws {
        let store = try makeStore()
        let key = Contribution.bigramKey(previous: "ва", word: "кӏвал")
        store.enqueueContribution(kind: .bigramDelta, key: key, typedDelta: 1)

        let rows = store.contributionBatch(try XCTUnwrap(store.claimBatch()))
        let decoded = try XCTUnwrap(Contribution.decodeBigramKey(rows[0].key))
        XCTAssertEqual(decoded.previous, "ва")
        XCTAssertEqual(decoded.word, "кӏвал")
    }

    func testASeparatorBearingTokenCanNeverBeAValidKeyHalf() {
        // canonical() does NOT strip the separator — validation is the
        // gate. What makes the encoding unambiguous is that no token
        // carrying the separator can ever pass the validity check that
        // every key half must pass.
        let smuggler = "ва\u{1F}кӏ"
        XCTAssertTrue(Normalization.canonical(smuggler).contains(Character(Contribution.keySeparator)),
                      "Precondition: canonicalization alone does not remove it")
        XCTAssertFalse(Normalization.isValidToken(Normalization.canonical(smuggler)))
        XCTAssertNil(Contribution.decodeBigramKey(
            Contribution.bigramKey(previous: smuggler, word: "кӏвал")),
            "A forged half means the whole key decodes to nothing")
    }

    // MARK: - Key contract

    func testWordKeysCarryingTheSeparatorAreRefused() throws {
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "ва\u{1F}кӏвал", typedDelta: 1)
        store.enqueueContribution(kind: .candidate, key: "ва\u{1F}кӏвал", typedDelta: 1)
        XCTAssertEqual(store.pendingContributionCount, 0,
                       "A word key that smuggles the separator would forge a bigram")
    }

    func testNonCanonicalKeysAreRefused() throws {
        // A non-canonical key would split one word's counters across
        // parallel rows. By the time a word reaches contribution recording
        // it has already passed the canonical write path, so a non-canonical
        // key here is an upstream bug — refused, not silently repaired.
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "КӀВАЛ", typedDelta: 1)
        store.enqueueContribution(kind: .wordDelta, key: "\u{0438}\u{0306}ис", typedDelta: 1)
        store.enqueueContribution(kind: .wordDelta, key: " кӏвал", typedDelta: 1)
        XCTAssertEqual(store.pendingContributionCount, 0)
    }

    func testInvalidTokensAreRefusedAsKeys() throws {
        let store = try makeStore()
        for key in ["гаф1", "а", "iphone", "гаф.гаф"] {
            store.enqueueContribution(kind: .wordDelta, key: key, typedDelta: 1)
        }
        XCTAssertEqual(store.pendingContributionCount, 0,
                       "What the contract would never export must never be queued")
    }

    func testMalformedBigramKeysAreRefused() throws {
        let store = try makeStore()
        let sep = Contribution.keySeparator
        let malformed = [
            "кӏвал",                          // no separator: not a pair
            "ва\(sep)кӏвал\(sep)зи",          // two separators: which pair?
            "ва\(sep)",                       // empty half
            "ва\(sep)гаф1",                   // invalid half
            "ва\(sep)КӀВАЛ",                  // non-canonical half
        ]
        for key in malformed {
            XCTAssertNil(Contribution.decodeBigramKey(key), "must not decode: \(key)")
            store.enqueueContribution(kind: .bigramDelta, key: key, typedDelta: 1)
        }
        XCTAssertEqual(store.pendingContributionCount, 0)
    }

    func testBigramEncodingIsInjective() {
        // The classic ambiguity: both pairs concatenate to «вакӏвал», and
        // only the separator's position tells them apart. Since no valid
        // token can contain the separator, that position is unique.
        let a = Contribution.bigramKey(previous: "вакӏ", word: "вал")
        let b = Contribution.bigramKey(previous: "ва", word: "кӏвал")
        XCTAssertNotEqual(a, b)

        let decodedA = Contribution.decodeBigramKey(a)
        let decodedB = Contribution.decodeBigramKey(b)
        XCTAssertEqual(decodedA?.previous, "вакӏ")
        XCTAssertEqual(decodedA?.word, "вал")
        XCTAssertEqual(decodedB?.previous, "ва")
        XCTAssertEqual(decodedB?.word, "кӏвал")
    }

    func testDecodingAValidKeyYieldsExactlyItsPair() {
        let pairs = [("зи", "хайи"), ("кьуьзуь", "цӏийи"), ("къуьл", "чӏал")]
        for (previous, word) in pairs {
            let decoded = Contribution.decodeBigramKey(Contribution.bigramKey(previous: previous, word: word))
            XCTAssertEqual(decoded?.previous, previous)
            XCTAssertEqual(decoded?.word, word)
        }
    }

    // MARK: - Structural privacy

    func testEveryColumnIsATokenOrAnInteger() throws {
        _ = try makeStore()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("learned.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA table_info(outbox)", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }

        var textColumns: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 1))
            let type = String(cString: sqlite3_column_text(stmt, 2))
            if type == "TEXT" { textColumns.append(name) }
        }
        // The only text in the table is the kind enum, the aggregation key
        // (canonical tokens), and a batch UUID. Adding a text column here
        // should require deleting this assertion on purpose.
        XCTAssertEqual(textColumns.sorted(), ["batch_id", "key", "kind"],
                       "A new TEXT column is a new place for free text to hide")
    }

    func testEmptyKeysAreRefused() throws {
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "", typedDelta: 1)
        XCTAssertEqual(store.pendingContributionCount, 0)
    }

    // MARK: - Candidate threshold

    func testCandidatesBelowTheConfirmationBarDoNotEnterABatch() throws {
        let store = try makeStore()
        for _ in 0..<(Contribution.candidateMinimumConfirmations - 1) {
            store.enqueueContribution(kind: .candidate, key: "гьуьлуьхъ", typedDelta: 1)
        }
        XCTAssertEqual(store.pendingContributionCount, 1, "It is queued…")
        XCTAssertNil(store.claimBatch(), "…but not eligible to leave")
    }

    func testCandidatesAtTheBarBecomeEligible() throws {
        let store = try makeStore()
        for _ in 0..<Contribution.candidateMinimumConfirmations {
            store.enqueueContribution(kind: .candidate, key: "гьуьлуьхъ", typedDelta: 1)
        }
        let rows = store.contributionBatch(try XCTUnwrap(store.claimBatch()))
        XCTAssertEqual(rows.map(\.key), ["гьуьлуьхъ"])
    }

    func testKnownWordsAreNotSubjectToTheCandidateBar() throws {
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 1)
        XCTAssertNotNil(store.claimBatch(),
                        "A dictionary word is not the sensitive category")
    }

    // MARK: - Capacity and retention

    func testStaleRowsAreDropped() throws {
        let store = try makeStore()
        let old = at(365)
        store.enqueueContribution(kind: .wordDelta, key: "кьуьзуь", typedDelta: 1, now: old)
        XCTAssertEqual(store.pendingContributionCount, 1)

        // Any later write runs the prune.
        store.enqueueContribution(kind: .wordDelta, key: "цӏийи", typedDelta: 1, now: at(0))

        let keys = store.contributionBatch(try XCTUnwrap(store.claimBatch())).map(\.key)
        XCTAssertEqual(keys, ["цӏийи"], "The year-old row is past retention")
    }

    func testFreshRowsSurviveTheRetentionSweep() throws {
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "кьуьзуь", typedDelta: 1, now: at(30))
        store.enqueueContribution(kind: .wordDelta, key: "цӏийи", typedDelta: 1, now: at(0))
        XCTAssertEqual(store.pendingContributionCount, 2)
    }

    func testTheQueueIsBoundedByMaxRows() throws {
        let store = try makeStore()
        // Every key distinct, so aggregation cannot do the bounding here.
        for i in 0..<(Contribution.maxRows + 200) {
            store.enqueueContribution(kind: .wordDelta, key: distinctKey(i), typedDelta: 1)
        }
        // Exactly maxRows, not merely ≤: an upper-bound-only assertion
        // would also pass if every key were refused at the door and the
        // queue stayed empty.
        XCTAssertEqual(store.pendingContributionCount, Contribution.maxRows)
    }

    func testPruningKeepsTheMostConfirmedRows() throws {
        let store = try makeStore()
        for _ in 0..<21 {
            store.enqueueContribution(kind: .wordDelta, key: "лезги", typedDelta: 1)
        }
        for i in 0..<(Contribution.maxRows + 100) {
            store.enqueueContribution(kind: .wordDelta, key: distinctKey(i), typedDelta: 1)
        }
        XCTAssertEqual(store.pendingContributionCount, Contribution.maxRows,
                       "Precondition: eviction pressure actually happened")
        let surviving = store.contributionBatch(try XCTUnwrap(store.claimBatch(limit: Contribution.maxRows)))
        XCTAssertTrue(surviving.contains { $0.key == "лезги" },
                      "Pressure must evict the incidental, not the reinforced")
    }

    func testClaimedRowsAreNeverPruned() throws {
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "чӏал", typedDelta: 1, now: at(365))
        let batch = try XCTUnwrap(store.claimBatch())

        store.enqueueContribution(kind: .wordDelta, key: "цӏийи", typedDelta: 1, now: at(0))

        XCTAssertEqual(store.contributionBatch(batch).count, 1,
                       "A batch in flight must not lose rows underneath its exporter")
    }

    // MARK: - Batch lifecycle

    func testAClaimedRowLeavesThePendingQueue() throws {
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 1)
        _ = try XCTUnwrap(store.claimBatch())
        XCTAssertEqual(store.pendingContributionCount, 0)
    }

    func testClaimingAnEmptyQueueReturnsNil() throws {
        let store = try makeStore()
        XCTAssertNil(store.claimBatch())
    }

    func testASecondClaimDoesNotStealTheFirstBatchesRows() throws {
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 1)
        store.enqueueContribution(kind: .wordDelta, key: "хайи", typedDelta: 1)

        let first = try XCTUnwrap(store.claimBatch(limit: 1))
        let second = try XCTUnwrap(store.claimBatch(limit: 1))

        XCTAssertNotEqual(first, second)
        XCTAssertEqual(store.contributionBatch(first).count, 1)
        XCTAssertEqual(store.contributionBatch(second).count, 1)
        XCTAssertNotEqual(store.contributionBatch(first)[0].key,
                          store.contributionBatch(second)[0].key)
    }

    func testEventsDuringAnInFlightBatchStartAFreshRow() throws {
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 5)
        let batch = try XCTUnwrap(store.claimBatch())

        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 1)

        XCTAssertEqual(store.contributionBatch(batch)[0].typed, 5,
                       "The claimed snapshot must not move under the exporter")
        XCTAssertEqual(store.pendingContributionCount, 1,
                       "…and the new event is not lost either")
    }

    func testReadingABatchTwiceYieldsIdenticalContent() throws {
        let store = try makeStore()
        for word in ["кӏвал", "хайи", "къуьл"] {
            store.enqueueContribution(kind: .wordDelta, key: word, typedDelta: 2)
        }
        let batch = try XCTUnwrap(store.claimBatch())

        let first = store.contributionBatch(batch)
        let second = store.contributionBatch(batch)
        XCTAssertEqual(first.map(\.key), second.map(\.key), "Same order")
        XCTAssertEqual(first.map(\.typed), second.map(\.typed), "Same counters")
    }

    func testAcknowledgementRemovesOnlyThatBatch() throws {
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 1)
        store.enqueueContribution(kind: .wordDelta, key: "хайи", typedDelta: 1)
        let first = try XCTUnwrap(store.claimBatch(limit: 1))
        let second = try XCTUnwrap(store.claimBatch(limit: 1))

        store.acknowledgeContributionBatch(first)

        XCTAssertTrue(store.contributionBatch(first).isEmpty)
        XCTAssertEqual(store.contributionBatch(second).count, 1)
    }

    func testDuplicateAcknowledgementIsHarmless() throws {
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 1)
        let batch = try XCTUnwrap(store.claimBatch())

        store.acknowledgeContributionBatch(batch)
        store.acknowledgeContributionBatch(batch)   // the server answered twice
        store.acknowledgeContributionBatch(UUID().uuidString)   // …or answered about nothing

        XCTAssertEqual(store.pendingContributionCount, 0)
        XCTAssertTrue(store.contributionBatch(batch).isEmpty)
    }

    func testAcknowledgingTheUnclaimedSentinelCannotWipeTheQueue() throws {
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 1)

        store.acknowledgeContributionBatch(Contribution.unclaimed)

        XCTAssertEqual(store.pendingContributionCount, 1,
                       "An empty batch id must never mean 'every unclaimed row'")
    }

    // MARK: - Crash recovery

    func testAClaimThatNeverCompletedIsRecoveredOnTheNextLaunch() throws {
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 7)
        let lost = try XCTUnwrap(store.claimBatch())
        XCTAssertEqual(store.pendingContributionCount, 0, "Precondition: in flight")
        // …and here the extension is killed, between claim and acknowledgement.

        let relaunched = try makeStore()
        relaunched.releaseStaleContributionClaims()

        XCTAssertEqual(relaunched.pendingContributionCount, 1, "Nothing lost")
        let rows = relaunched.contributionBatch(try XCTUnwrap(relaunched.claimBatch()))
        XCTAssertEqual(rows[0].typed, 7, "…and nothing double-counted")
        XCTAssertTrue(relaunched.contributionBatch(lost).isEmpty,
                      "The abandoned batch id no longer names any rows")
    }

    func testALateAcknowledgementOfAReleasedBatchDeletesNothing() throws {
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 3)
        let lost = try XCTUnwrap(store.claimBatch())
        store.releaseStaleContributionClaims()
        let reclaimed = try XCTUnwrap(store.claimBatch())

        store.acknowledgeContributionBatch(lost)   // a stale reply arriving late

        XCTAssertEqual(store.contributionBatch(reclaimed).count, 1,
                       "A stale acknowledgement must not delete re-queued work")
    }

    func testReleasingAClaimMergesIntoItsUnclaimedTwin() throws {
        // The identity crash: typing during an in-flight batch starts a
        // fresh unclaimed row for the same (kind, key). Releasing the claim
        // as a plain batch_id rename would collide with that twin on the
        // unique index, fail, and leave the rows claimed forever. Release
        // must merge instead.
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 5)
        let batch = try XCTUnwrap(store.claimBatch())
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 2)
        XCTAssertEqual(store.pendingContributionCount, 1, "Precondition: the twin exists")

        store.releaseContributionClaim(batch)

        XCTAssertEqual(store.claimedContributionBatchIDs, [], "The claim must actually clear")
        XCTAssertEqual(store.pendingContributionCount, 1, "One merged row, not two")
        let rows = store.contributionBatch(try XCTUnwrap(store.claimBatch()))
        XCTAssertEqual(rows[0].typed, 7, "5 released + 2 new; nothing lost, nothing doubled")
    }

    func testReleaseMergesNothingAndLosesNothingAcrossSeveralBatches() throws {
        let store = try makeStore()
        for word in ["кӏвал", "хайи", "къуьл"] {
            store.enqueueContribution(kind: .wordDelta, key: word, typedDelta: 1)
        }
        _ = try XCTUnwrap(store.claimBatch(limit: 1))
        _ = try XCTUnwrap(store.claimBatch(limit: 1))

        store.releaseStaleContributionClaims()

        XCTAssertEqual(store.pendingContributionCount, 3)
    }

    func testTheQueueSurvivesReopeningTheDatabase() throws {
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 4)

        let reopened = try makeStore()
        XCTAssertEqual(reopened.pendingContributionCount, 1, "Durable, not in-memory")
        XCTAssertEqual(reopened.contributionBatch(try XCTUnwrap(reopened.claimBatch()))[0].typed, 4)
    }

    // MARK: - Counter saturation

    private func rawOutboxInt(_ sql: String) -> Int {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("learned.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return -1 }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func rawOutboxExec(_ sql: String) {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("learned.sqlite").path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    private let ceiling = 1_000_000_000

    func testAHugeDeltaIsClampedOnTheFirstInsert() throws {
        // The ON CONFLICT arm has always saturated; the first INSERT is the
        // arm that would have taken Int.max raw.
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: Int.max)
        XCTAssertEqual(rawOutboxInt("SELECT typed_delta FROM outbox"), ceiling)
    }

    func testAccumulationSaturatesAtTheCeiling() throws {
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: Int.max)
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал",
                                  typedDelta: Int.max, pickedDelta: Int.max)
        XCTAssertEqual(rawOutboxInt("SELECT typed_delta FROM outbox"), ceiling)
        XCTAssertEqual(rawOutboxInt("SELECT picked_delta FROM outbox"), ceiling)
    }

    func testNegativeDeltasClampToZero() throws {
        // Counters are monotonic; a negative delta is an upstream bug and
        // must not become a decrement.
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 5)
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: -100, pickedDelta: -1)
        XCTAssertEqual(rawOutboxInt("SELECT typed_delta FROM outbox"), 5)
        XCTAssertEqual(rawOutboxInt("SELECT picked_delta FROM outbox"), 0)
    }

    func testAMalformedStoredValueCannotOverflow() throws {
        // A corrupted or hostile database with a counter at Int64.max:
        // SQLite falls back to REAL arithmetic on integer overflow, and the
        // MIN with the ceiling brings the value straight back into range.
        let store = try makeStore()
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 1)
        rawOutboxExec("UPDATE outbox SET typed_delta = 9223372036854775807, confirmations = 9223372036854775807")

        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 1)

        XCTAssertEqual(rawOutboxInt("SELECT typed_delta FROM outbox"), ceiling)
        XCTAssertEqual(rawOutboxInt("SELECT confirmations FROM outbox"), ceiling)
        let rows = store.contributionBatch(try XCTUnwrap(store.claimBatch()))
        XCTAssertEqual(rows[0].typed, ceiling, "…and the Swift read side survives it too")
    }

    // MARK: - Event semantics (the pure mapping)

    func testManuallyTypedKnownWordIsTypedOnly() {
        let events = Contribution.commitEvents(word: "кӏвал", previous: nil, picked: false,
                                               wordIsInDictionary: true, previousIsInDictionary: false)
        XCTAssertEqual(events, [CommitEvent(kind: .wordDelta, key: "кӏвал",
                                            typedDelta: 1, pickedDelta: 0)])
    }

    func testPickedKnownWordIsPickedOnlyNeverAlsoTyped() {
        // typed and picked partition the commits, so typed+picked is the
        // total commit count. Double-counting a pick as a typing would
        // poison every future acceptance-rate calculation.
        let events = Contribution.commitEvents(word: "кӏвал", previous: nil, picked: true,
                                               wordIsInDictionary: true, previousIsInDictionary: false)
        XCTAssertEqual(events, [CommitEvent(kind: .wordDelta, key: "кӏвал",
                                            typedDelta: 0, pickedDelta: 1)])
    }

    func testUnknownWordIsACandidateNotAWordDelta() {
        let typed = Contribution.commitEvents(word: "гьуьлуьхъ", previous: nil, picked: false,
                                              wordIsInDictionary: false, previousIsInDictionary: false)
        XCTAssertEqual(typed, [CommitEvent(kind: .candidate, key: "гьуьлуьхъ",
                                           typedDelta: 1, pickedDelta: 0)])

        let picked = Contribution.commitEvents(word: "гьуьлуьхъ", previous: nil, picked: true,
                                               wordIsInDictionary: false, previousIsInDictionary: false)
        XCTAssertEqual(picked, [CommitEvent(kind: .candidate, key: "гьуьлуьхъ",
                                            typedDelta: 0, pickedDelta: 1)])
    }

    func testEachCandidateCommitIsOneConfirmation() throws {
        // The confirmation counter lives in the queue, incremented once per
        // enqueue — so one commit is one confirmation, however it happened.
        let store = try makeStore()
        for event in Contribution.commitEvents(word: "гьуьлуьхъ", previous: nil, picked: false,
                                               wordIsInDictionary: false, previousIsInDictionary: false) {
            store.enqueueContribution(kind: event.kind, key: event.key,
                                      typedDelta: event.typedDelta, pickedDelta: event.pickedDelta)
        }
        XCTAssertEqual(rawOutboxInt("SELECT confirmations FROM outbox"), 1)
    }

    func testBigramFiresOnlyWhenBothSidesAreDictionaryWords() {
        // A pair of names identifies more than either name alone, so
        // unknown words never enter pair context — from either side.
        let unknownWord = Contribution.commitEvents(word: "гьуьлуьхъ", previous: "зи", picked: false,
                                                    wordIsInDictionary: false, previousIsInDictionary: true)
        XCTAssertEqual(unknownWord.map(\.kind), [.candidate])

        let unknownPrevious = Contribution.commitEvents(word: "кӏвал", previous: "гьуьлуьхъ", picked: false,
                                                        wordIsInDictionary: true, previousIsInDictionary: false)
        XCTAssertEqual(unknownPrevious.map(\.kind), [.wordDelta])
    }

    func testBigramDeltaIsAlwaysTypedOne() {
        // The bigram records that the pair occurred; how the second word
        // was entered is the word event's business.
        for picked in [false, true] {
            let events = Contribution.commitEvents(word: "хайи", previous: "зи", picked: picked,
                                                   wordIsInDictionary: true, previousIsInDictionary: true)
            XCTAssertEqual(events.count, 2)
            XCTAssertEqual(events[1], CommitEvent(kind: .bigramDelta,
                                                  key: Contribution.bigramKey(previous: "зи", word: "хайи"),
                                                  typedDelta: 1, pickedDelta: 0))
        }
    }

    func testInvalidWordProducesNoEventsAtAll() {
        for word in ["гаф1", "а", "КӀВАЛ", "iphone"] {
            let events = Contribution.commitEvents(word: word, previous: "зи", picked: false,
                                                   wordIsInDictionary: true, previousIsInDictionary: true)
            XCTAssertEqual(events, [], "\(word) must contribute nothing, not even the bigram")
        }
    }

    func testInvalidPreviousDropsOnlyTheBigram() {
        let events = Contribution.commitEvents(word: "кӏвал", previous: "гаф1", picked: false,
                                               wordIsInDictionary: true, previousIsInDictionary: true)
        XCTAssertEqual(events, [CommitEvent(kind: .wordDelta, key: "кӏвал",
                                            typedDelta: 1, pickedDelta: 0)])
    }

    func testDeletingALearnedWordTouchesNoCounters() throws {
        // Events fire at commit, once. Correcting or deleting the word
        // afterwards produces nothing: a decrement would need exactly the
        // keystroke-level observation this design refuses to make.
        let store = try makeStore()
        store.learn("кӏвал", previous: nil, picked: false)
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 1)

        store.delete("кӏвал")

        XCTAssertEqual(rawOutboxInt("SELECT typed_delta FROM outbox"), 1,
                       "delete() unlearns the word; it does not rewrite history")
    }

    func testRecordCommitIsGated() throws {
        let store = try makeStore()
        store.setContributionConsent(true)   // consent alone; the flag stays off
        store.recordCommit(word: "кӏвал", previous: "зи", picked: false,
                           wordIsInDictionary: true, previousIsInDictionary: true)
        XCTAssertEqual(store.pendingContributionCount, 0)
    }

    // MARK: - Existing behavior is untouched

    func testLearningStillWorksWithTheOutboxPresent() throws {
        let store = try makeStore()
        store.learn("кӏвал", previous: "ва", picked: false)
        store.learn("кӏвал", previous: "ва", picked: true)

        XCTAssertTrue(store.isRecognized("кӏвал"))
        XCTAssertEqual(store.pendingContributionCount, 0,
                       "Typing must not feed the queue while the gate is closed")
    }
}
