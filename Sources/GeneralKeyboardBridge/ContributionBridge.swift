//
//  ContributionBridge.swift
//  GeneralKeyboardBridge
//
//  The file protocol between the keyboard's outbox and the containing app:
//
//      learned.sqlite outbox ── claim ──► outgoing/<batch>.json
//      containing app ── reads outgoing, writes ──► ack/<batch>.ack
//      keyboard ── sees ack ──► acknowledge (rows deleted), files removed
//
//  This file is the SHARED half of the protocol — compiled into both the
//  keyboard extension and the containing app, so the two sides can never
//  drift apart on the format. The keyboard-side exporter lives in
//  ContributionExporter.swift (extension target only). Every function
//  takes the bridge directory as a parameter; the production directory is
//  the App Group container exposed by `productionDirectory(appGroupID:)`.
//
//  DESIGN RULES
//    * No shared writable database. Each file has exactly one writer:
//      the keyboard writes outgoing/, the app writes ack/. Handoff is by
//      rename, which is atomic on the same volume, so a reader can never
//      observe a half-written file.
//    * The keyboard never exports unless the full gate holds: build flag,
//      user consent, writable store, AND Full Access. Any of them missing
//      means no file is written and no claim is left dangling.
//    * A batch file contains the format version, the batch id, and the
//      aggregated rows. No timestamps of any kind — see
//      docs/CONTRIBUTION_OUTBOX.md §9 — and nothing about the device or
//      the person.
//    * Serialization is deterministic (sorted keys, claim order), so
//      re-exporting the same batch is byte-identical and a retry can be
//      deduplicated by content as well as by id.
//

import Foundation

// MARK: - The serialized batch format

/// Version 1 of the bridge file format. Bumped only with a reviewed
/// change; readers refuse versions they do not know.
public struct ContributionBatchFile: Codable, Equatable, Sendable {
    public struct Row: Codable, Equatable, Sendable {
        public let kind: String
        public let key: String
        public let typed: Int
        public let picked: Int
        public let confirmations: Int

        public init(kind: String, key: String, typed: Int, picked: Int, confirmations: Int) {
            self.kind = kind
            self.key = key
            self.typed = typed
            self.picked = picked
            self.confirmations = confirmations
        }
    }

    public let format: Int
    public let batch: String
    public let rows: [Row]

    public init(format: Int, batch: String, rows: [Row]) {
        self.format = format
        self.batch = batch
        self.rows = rows
    }

    public static let currentFormat = 1

    /// Deterministic bytes: sorted keys, no formatting whitespace, rows in
    /// claim (id) order as `contributionBatch` returns them.
    public func serialized() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func parse(_ data: Data) -> ContributionBatchFile? {
        guard let file = try? JSONDecoder().decode(ContributionBatchFile.self, from: data),
              file.format == currentFormat else { return nil }
        return file
    }
}

// MARK: - Shared directory layout

public enum ContributionBridge {

    /// The production bridge directory: the App Group container both
    /// targets are entitled to. Every keyboard in the family has its OWN
    /// group (group.org.lekitech.<language>keyboard), supplied by the product
    /// — bridges are never shared across keyboards, so one keyboard's
    /// contribution data is structurally invisible to another's. Nil when
    /// the entitlement is absent — unit tests, which inject their own
    /// directories everywhere. Nothing reads or writes through this while
    /// `Contribution.isEnabled` is false: the keyboard's exporter is
    /// triple-gated, and the app's pickup only ever sees files that
    /// exporter wrote.
    public static func productionDirectory(appGroupID: String) -> URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    /// Batches the keyboard has exported and the app has not yet
    /// acknowledged. Written only by the keyboard.
    package static func outgoingDirectory(in bridge: URL) -> URL {
        bridge.appendingPathComponent("Contribution/outgoing", isDirectory: true)
    }

    /// Acknowledgements. Written only by the app.
    package static func ackDirectory(in bridge: URL) -> URL {
        bridge.appendingPathComponent("Contribution/ack", isDirectory: true)
    }

    /// Scratch space for atomic writes; files are renamed out of here.
    package static func stagingDirectory(in bridge: URL) -> URL {
        bridge.appendingPathComponent("Contribution/tmp", isDirectory: true)
    }

    /// The keyboard stops claiming new batches once this many exported
    /// files are waiting — the "containing app never opened" bound. The
    /// outbox's own row cap bounds the database side.
    package static let maxPendingFiles = 3

    /// A batch file may not exceed this size; the exporter halves the row
    /// limit until the serialized batch fits. 128 KB is deliberately LOW
    /// enough that a 500-row batch of maximum-length bigram keys (~165 KB)
    /// actually exceeds it — a cap no reachable batch can hit is not a cap,
    /// and the shrinking path would be dead code.
    package static let maxBatchBytes = 131_072

    /// An exported file the app has not picked up after this long is
    /// withdrawn: the file is deleted and its rows return to the queue,
    /// counters intact. Uses filesystem metadata, not exported content.
    package static let pendingFileRetention: TimeInterval = 30 * 24 * 3600

    /// Atomic publication: write to the staging directory, then rename
    /// into place. Rename is atomic on the same volume, so `destination`
    /// either does not exist or is complete — never partial.
    package static func atomicWrite(_ data: Data, to destination: URL, in bridge: URL) throws {
        let staging = stagingDirectory(in: bridge)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let temp = staging.appendingPathComponent(UUID().uuidString)
        try data.write(to: temp)
        do {
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch {
            // Lost the race to a file that already exists (a retry of the
            // same batch): the existing bytes are identical by determinism,
            // so keeping them is correct.
            try? FileManager.default.removeItem(at: temp)
            if !FileManager.default.fileExists(atPath: destination.path) { throw error }
        }
    }
}

// MARK: - App side: the inbox

/// The containing app's half: read exported batches, acknowledge them.
/// Owns no database and holds no state — the filesystem is the state.
public enum ContributionInbox {

    /// Parses every well-formed batch waiting in the bridge and writes an
    /// acknowledgement for each. Malformed or foreign files are left in
    /// place untouched — never acknowledged (an ack deletes the keyboard's
    /// rows, so acking what could not be read would destroy data), never
    /// deleted (the keyboard's retention handles withdrawal).
    ///
    /// In this proof of concept "picked up" means parsed and returned to
    /// the caller. The upload phase will move acknowledgement to after
    /// server acceptance; the protocol does not change.
    @discardableResult
    public static func pickUp(from bridge: URL) -> [ContributionBatchFile] {
        let fm = FileManager.default
        let outgoing = ContributionBridge.outgoingDirectory(in: bridge)
        let ack = ContributionBridge.ackDirectory(in: bridge)
        try? fm.createDirectory(at: ack, withIntermediateDirectories: true)

        var pickedUp: [ContributionBatchFile] = []
        for file in (try? fm.contentsOfDirectory(at: outgoing, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let batch = ContributionBatchFile.parse(data),
                  batch.batch == file.deletingPathExtension().lastPathComponent
            else { continue }
            let ackFile = ack.appendingPathComponent("\(batch.batch).ack")
            guard (try? ContributionBridge.atomicWrite(Data(batch.batch.utf8),
                                                       to: ackFile, in: bridge)) != nil
            else { continue }
            pickedUp.append(batch)
        }
        return pickedUp
    }
}
