//
//  ContributionExporter.swift
//  GeneralKeyboard
//
//  The keyboard's half of the contribution bridge — everything that
//  touches learned.sqlite. Compiled into the extension target only; the
//  shared format, directory layout, and app-side inbox live in
//  ContributionBridge.swift. See that file's header for the protocol.
//

import Foundation
import GeneralKeyboardBridge

// MARK: - Keyboard side: the exporter

extension LearnedWords {

    /// Everything the keyboard's bridge pass does, in order: recover,
    /// enforce bounds, export. Call sites do not exist yet — the gate is
    /// closed and the production bridge directory does not exist — but the
    /// whole lifecycle is exercised by tests through this one entry point.
    ///
    /// `hasFullAccess` is a parameter rather than a UIKit read so the
    /// policy is testable; the future call site passes
    /// `UIInputViewController.hasFullAccess`.
    /// Returns the URL of a newly exported batch file, if one was written.
    @discardableResult
    func runContributionBridge(at bridge: URL, hasFullAccess: Bool) -> URL? {
        guard Contribution.isEnabled else { return nil }
        return runContributionBridgeIgnoringFlag(at: bridge, hasFullAccess: hasFullAccess)
    }

    /// Ungated variant for tests — the same reason enqueueContribution has
    /// one: the flag is a genuine compile-time `false`.
    @discardableResult
    func runContributionBridgeIgnoringFlag(at bridge: URL, hasFullAccess: Bool) -> URL? {
        guard !isReadOnly, hasContributionConsent, hasFullAccess else {
            // Not eligible. Deliberately do nothing at all: no recovery, no
            // cleanup, no directory creation. Losing Full Access between a
            // claim and an export leaves the claim in place; the rows are
            // frozen, not lost, and the next eligible pass recovers them.
            return nil
        }

        let fm = FileManager.default
        let outgoing = ContributionBridge.outgoingDirectory(in: bridge)
        let ack = ContributionBridge.ackDirectory(in: bridge)
        try? fm.createDirectory(at: outgoing, withIntermediateDirectories: true)
        try? fm.createDirectory(at: ack, withIntermediateDirectories: true)

        // 1. Consume acknowledgements: delete the batch's rows, then both
        //    files. Ack-before-file-removal order means a crash here leaves
        //    an ack for an already-deleted batch — and acknowledging an
        //    unknown id is a no-op, so the retry is harmless.
        for ackFile in (try? fm.contentsOfDirectory(at: ack, includingPropertiesForKeys: nil)) ?? []
        where ackFile.pathExtension == "ack" {
            let batchID = ackFile.deletingPathExtension().lastPathComponent
            acknowledgeContributionBatch(batchID)
            try? fm.removeItem(at: outgoing.appendingPathComponent("\(batchID).json"))
            try? fm.removeItem(at: ackFile)
        }

        let pendingFiles = ((try? fm.contentsOfDirectory(at: outgoing, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }

        // 2. Withdraw exported files the app has ignored past retention:
        //    delete the file FIRST, then release the rows. A crash between
        //    the two leaves a claimed batch with no file — exactly what
        //    step 3 recovers. The reverse order could duplicate rows into
        //    a second file while the first still existed.
        var remaining: [URL] = []
        for file in pendingFiles {
            let age = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate.map { -$0.timeIntervalSinceNow } ?? 0
            if age > ContributionBridge.pendingFileRetention {
                try? fm.removeItem(at: file)
                releaseContributionClaim(file.deletingPathExtension().lastPathComponent)
            } else {
                remaining.append(file)
            }
        }

        // 3. Recover claims that died between claiming and writing: a
        //    claimed batch with no file on disk can never be acknowledged,
        //    so its rows go back to the queue, counters intact.
        let onDisk = Set(remaining.map { $0.deletingPathExtension().lastPathComponent })
        for batchID in claimedContributionBatchIDs where !onDisk.contains(batchID) {
            releaseContributionClaim(batchID)
        }

        // 4. Export one new batch, if there is room and material.
        guard remaining.count < ContributionBridge.maxPendingFiles else { return nil }
        return exportOneBatch(to: outgoing, in: bridge)
    }

    private func exportOneBatch(to outgoing: URL, in bridge: URL) -> URL? {
        var limit = 500
        while limit >= 1 {
            guard let batchID = claimBatch(limit: limit) else { return nil }
            let rows = contributionBatch(batchID).map {
                ContributionBatchFile.Row(kind: $0.kind, key: $0.key, typed: $0.typed,
                                          picked: $0.picked, confirmations: $0.confirmations)
            }
            let file = ContributionBatchFile(format: ContributionBatchFile.currentFormat,
                                             batch: batchID, rows: rows)
            guard let data = try? file.serialized() else {
                releaseContributionClaim(batchID)
                return nil
            }
            guard data.count <= ContributionBridge.maxBatchBytes else {
                // Too big: put the rows back and try a smaller claim. The
                // released rows re-queue in id order, so the next claim
                // takes the same head rows — nothing is skipped.
                releaseContributionClaim(batchID)
                limit /= 2
                continue
            }
            let destination = outgoing.appendingPathComponent("\(batchID).json")
            do {
                try ContributionBridge.atomicWrite(data, to: destination, in: bridge)
                return destination
            } catch {
                // Nothing reached the outgoing directory, so releasing the
                // claim leaves the world exactly as before this call.
                releaseContributionClaim(batchID)
                return nil
            }
        }
        return nil
    }
}
