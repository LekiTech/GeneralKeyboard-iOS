//
//  ContributionBridgeTests.swift
//
//  The outbox → file → app → acknowledgement loop, exercised end to end in
//  temporary directories. The bridge directory is a parameter everywhere,
//  so these tests prove the protocol without an App Group, entitlements,
//  or Full Access existing at all.
//

import XCTest
@testable import GeneralKeyboard
@testable import GeneralKeyboardBridge
import GeneralKeyboardReference

final class ContributionBridgeTests: GKTestCase {

    private var dir: URL!      // the store's home
    private var bridge: URL!   // stands in for the App Group container

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bridge-\(UUID().uuidString)")
        dir = base.appendingPathComponent("store")
        bridge = base.appendingPathComponent("group")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: bridge, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    /// A store with consent granted and a few queued contributions — the
    /// state an eligible exporter would actually see.
    private func makeEligibleStore(words: [String] = ["кӏвал", "хайи", "къуьл"]) throws -> LearnedWords {
        let store = try XCTUnwrap(LearnedWords(directory: dir))
        store.setContributionConsent(true)
        for (index, word) in words.enumerated() {
            store.enqueueContribution(kind: .wordDelta, key: word, typedDelta: index + 1)
        }
        return store
    }

    private func run(_ store: LearnedWords, fullAccess: Bool = true) -> URL? {
        store.runContributionBridgeIgnoringFlag(at: bridge, hasFullAccess: fullAccess)
    }

    private func outgoingFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: ContributionBridge.outgoingDirectory(in: bridge),
            includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
    }

    // MARK: - The gate, again, at the bridge

    func testTheGatedEntryPointIsInertWhileTheFlagIsOff() throws {
        let store = try makeEligibleStore()
        XCTAssertNil(store.runContributionBridge(at: bridge, hasFullAccess: true))
        XCTAssertEqual(outgoingFiles(), [], "The shipping entry point must do nothing")
    }

    func testNoExportWithoutFullAccess() throws {
        let store = try makeEligibleStore()
        XCTAssertNil(run(store, fullAccess: false))
        XCTAssertEqual(outgoingFiles(), [])
        XCTAssertEqual(store.pendingContributionCount, 3, "…and no claim is left dangling")
    }

    func testNoExportWithoutConsent() throws {
        let store = try XCTUnwrap(LearnedWords(directory: dir))
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 1)
        XCTAssertNil(run(store))
        XCTAssertEqual(outgoingFiles(), [])
    }

    func testAnIneligiblePassTouchesNothingOnDisk() throws {
        // Losing Full Access must freeze the world, not tidy it.
        let store = try makeEligibleStore()
        let file = try XCTUnwrap(run(store))
        XCTAssertNil(run(store, fullAccess: false))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                      "The exported file waits for an eligible pass")
    }

    // MARK: - Export

    func testAnEligiblePassExportsOneDeterministicFile() throws {
        let store = try makeEligibleStore()
        let file = try XCTUnwrap(run(store))

        let data = try Data(contentsOf: file)
        let parsed = try XCTUnwrap(ContributionBatchFile.parse(data))
        XCTAssertEqual(parsed.format, 1)
        XCTAssertEqual(parsed.batch, file.deletingPathExtension().lastPathComponent)
        XCTAssertEqual(parsed.rows.map(\.key), ["кӏвал", "хайи", "къуьл"],
                       "Claim (id) order, not alphabetical")
        XCTAssertEqual(parsed.rows.map(\.typed), [1, 2, 3])
        XCTAssertEqual(store.pendingContributionCount, 0, "The rows are claimed, not deleted")
    }

    func testTheFileContainsNoTimestamps() throws {
        let store = try makeEligibleStore()
        let file = try XCTUnwrap(run(store))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["format", "batch", "rows"])
        let rows = try XCTUnwrap(json["rows"] as? [[String: Any]])
        for row in rows {
            XCTAssertEqual(Set(row.keys), ["kind", "key", "typed", "picked", "confirmations"],
                           "first_seen/updated_at are retention machinery and must not export")
        }
    }

    func testSerializationIsByteIdenticalOnRetry() throws {
        let store = try makeEligibleStore()
        _ = try XCTUnwrap(run(store))
        let batchID = try XCTUnwrap(store.claimedContributionBatchIDs.first)

        let rows = store.contributionBatch(batchID).map {
            ContributionBatchFile.Row(kind: $0.kind, key: $0.key, typed: $0.typed,
                                      picked: $0.picked, confirmations: $0.confirmations)
        }
        let again = ContributionBatchFile(format: 1, batch: batchID, rows: rows)
        XCTAssertEqual(try again.serialized(),
                       try Data(contentsOf: outgoingFiles()[0]),
                       "A retried export of the same batch must be byte-identical")
    }

    func testEventsDuringExportDoNotLeakIntoTheFile() throws {
        let store = try makeEligibleStore()
        let file = try XCTUnwrap(run(store))
        store.enqueueContribution(kind: .wordDelta, key: "кӏвал", typedDelta: 100)

        let parsed = try XCTUnwrap(ContributionBatchFile.parse(try Data(contentsOf: file)))
        XCTAssertEqual(parsed.rows.first { $0.key == "кӏвал" }?.typed, 1,
                       "The exported snapshot is frozen at claim time")
        XCTAssertEqual(store.pendingContributionCount, 1, "The new event queues separately")
    }

    // MARK: - The full loop

    func testTheFullLoopDeliversAcknowledgesAndCleansUp() throws {
        let store = try makeEligibleStore()
        _ = try XCTUnwrap(run(store))

        // The containing app opens.
        let pickedUp = ContributionInbox.pickUp(from: bridge)
        XCTAssertEqual(pickedUp.count, 1)
        XCTAssertEqual(pickedUp[0].rows.count, 3)

        // The keyboard's next pass consumes the acknowledgement.
        _ = run(store)

        XCTAssertEqual(outgoingFiles(), [], "Delivered file removed")
        XCTAssertEqual(store.claimedContributionBatchIDs, [], "No claim survives")
        XCTAssertEqual(store.pendingContributionCount, 0, "The rows are gone for good")
        let acks = (try? FileManager.default.contentsOfDirectory(
            at: ContributionBridge.ackDirectory(in: bridge), includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(acks, [], "Ack consumed")
    }

    func testDoublePickupIsIdempotent() throws {
        let store = try makeEligibleStore()
        _ = try XCTUnwrap(run(store))

        let first = ContributionInbox.pickUp(from: bridge)
        let second = ContributionInbox.pickUp(from: bridge)

        XCTAssertEqual(first, second, "The app crashed after pickup and re-ran: same result")
        _ = run(store)
        XCTAssertEqual(store.pendingContributionCount, 0, "One ack's worth of deletion, not two")
    }

    // MARK: - Crash windows

    func testAClaimThatNeverReachedDiskIsReleasedOnTheNextPass() throws {
        let store = try makeEligibleStore()
        let orphan = try XCTUnwrap(store.claimBatch())   // …and the extension dies here
        XCTAssertEqual(store.pendingContributionCount, 0)

        _ = run(store)

        XCTAssertTrue(store.contributionBatch(orphan).isEmpty, "The orphan claim is gone")
        // Its rows either re-queued or went straight into the fresh export.
        let files = outgoingFiles()
        XCTAssertEqual(files.count, 1)
        let parsed = try XCTUnwrap(ContributionBatchFile.parse(try Data(contentsOf: files[0])))
        XCTAssertEqual(parsed.rows.count, 3, "Nothing lost, nothing doubled")
    }

    func testAClaimWithAFileOnDiskIsNotReleased() throws {
        // The dual of the orphan case, and the reason the blanket release
        // is never used here: releasing a batch that HAS a file would let a
        // second claim duplicate its rows into a second file.
        let store = try makeEligibleStore()
        _ = try XCTUnwrap(run(store))
        let claimed = store.claimedContributionBatchIDs

        _ = run(store)   // a second pass: recovery must leave the claim alone

        XCTAssertEqual(store.claimedContributionBatchIDs, claimed)
        XCTAssertEqual(outgoingFiles().count, 1, "And no second file appears")
    }

    func testACrashBetweenAckConsumptionStepsIsHarmless() throws {
        // The keyboard acknowledged (rows deleted) but died before removing
        // the files. The next pass finds an ack for a batch that no longer
        // exists — acknowledging it again is a no-op and the files go away.
        let store = try makeEligibleStore()
        _ = try XCTUnwrap(run(store))
        _ = ContributionInbox.pickUp(from: bridge)
        let batchID = try XCTUnwrap(store.claimedContributionBatchIDs.first)
        store.acknowledgeContributionBatch(batchID)   // …and death before file removal

        _ = run(store)

        XCTAssertEqual(outgoingFiles(), [])
        XCTAssertEqual(store.pendingContributionCount, 0)
    }

    // MARK: - Bounds

    func testExportStopsWhenTheAppNeverOpens() throws {
        let store = try makeEligibleStore(words: [])
        let sourceWords = ["кӏвал", "хайи", "къуьл", "цӏийи", "чӏал", "лезги"]
        for (index, word) in sourceWords.enumerated() {
            store.enqueueContribution(kind: .wordDelta, key: word, typedDelta: index + 1)
            _ = run(store)   // one file per pass, nobody ever picks up
        }
        XCTAssertEqual(outgoingFiles().count, ContributionBridge.maxPendingFiles,
                       "The bridge is bounded even if the app is never opened")
        XCTAssertGreaterThan(store.pendingContributionCount, 0,
                             "The overflow stays safely in the queue")
    }

    func testWithdrawnStaleFilesReturnTheirRowsToTheQueue() throws {
        let store = try makeEligibleStore()
        let file = try XCTUnwrap(run(store))
        // Age the file past retention via filesystem metadata.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -ContributionBridge.pendingFileRetention - 60)],
            ofItemAtPath: file.path)

        _ = run(store)

        let files = outgoingFiles()
        XCTAssertEqual(files.count, 1, "The stale file was withdrawn; a fresh export replaced it")
        XCTAssertNotEqual(files[0].lastPathComponent, file.lastPathComponent)
        let parsed = try XCTUnwrap(ContributionBatchFile.parse(try Data(contentsOf: files[0])))
        XCTAssertEqual(parsed.rows.count, 3, "Counters came back intact and re-exported")
    }

    func testOversizedBatchesShrinkUntilTheyFit() throws {
        let store = try XCTUnwrap(LearnedWords(directory: dir))
        store.setContributionConsent(true)
        // ~1600 near-maximum bigram keys: a 500-row claim serializes past
        // maxBatchBytes, forcing at least one halving.
        let letters = ["а", "б", "в", "г", "д", "е", "ж", "з", "и", "к"]
        let long = String(repeating: "ва", count: 30)
        for i in 0..<1600 {
            let suffix = letters[i % 10] + letters[(i / 10) % 10] + letters[(i / 100) % 10]
                + letters[(i / 1000) % 10]
            let key = Contribution.bigramKey(previous: long, word: long + suffix)
            store.enqueueContribution(kind: .bigramDelta, key: key, typedDelta: 1)
        }

        let file = try XCTUnwrap(run(store))

        let data = try Data(contentsOf: file)
        XCTAssertLessThanOrEqual(data.count, ContributionBridge.maxBatchBytes)
        let parsed = try XCTUnwrap(ContributionBatchFile.parse(data))
        XCTAssertLessThan(parsed.rows.count, 500, "The claim was actually shrunk")
        XCTAssertGreaterThan(parsed.rows.count, 0)
    }

    // MARK: - The inbox is defensive

    func testMalformedFilesAreNeitherAcknowledgedNorDeleted() throws {
        let outgoing = ContributionBridge.outgoingDirectory(in: bridge)
        try FileManager.default.createDirectory(at: outgoing, withIntermediateDirectories: true)
        let garbage = outgoing.appendingPathComponent("\(UUID().uuidString).json")
        try Data("not json at all".utf8).write(to: garbage)

        let pickedUp = ContributionInbox.pickUp(from: bridge)

        XCTAssertEqual(pickedUp, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: garbage.path),
                      "Not the inbox's file to delete")
        let acks = (try? FileManager.default.contentsOfDirectory(
            at: ContributionBridge.ackDirectory(in: bridge), includingPropertiesForKeys: nil)) ?? []
        XCTAssertEqual(acks, [], "Acking what could not be read would destroy the keyboard's rows")
    }

    func testAFileWhoseNameDisagreesWithItsBatchIdIsRefused() throws {
        let store = try makeEligibleStore()
        let file = try XCTUnwrap(run(store))
        let renamed = file.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).json")
        try FileManager.default.moveItem(at: file, to: renamed)

        XCTAssertEqual(ContributionInbox.pickUp(from: bridge), [],
                       "An id mismatch means the file is not what its name claims")
    }

    func testAnUnknownFormatVersionIsRefused() throws {
        let outgoing = ContributionBridge.outgoingDirectory(in: bridge)
        try FileManager.default.createDirectory(at: outgoing, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let future = #"{"batch":"\#(id)","format":2,"rows":[]}"#
        try Data(future.utf8).write(to: outgoing.appendingPathComponent("\(id).json"))

        XCTAssertEqual(ContributionInbox.pickUp(from: bridge), [],
                       "A format from the future is not ours to acknowledge")
    }

    // MARK: - Consent withdrawal reaches the bridge state

    func testWithdrawingConsentAfterExportStopsTheLoop() throws {
        let store = try makeEligibleStore()
        _ = try XCTUnwrap(run(store))

        store.setContributionConsent(false)

        XCTAssertNil(run(store), "No further pass is eligible")
        XCTAssertEqual(store.pendingContributionCount, 0, "The queue emptied on withdrawal")
        // The exported file becomes an orphan the next ELIGIBLE pass would
        // clean up; consent-off passes touch nothing, which also means the
        // file stops being refreshed and ages toward retention.
    }
}
