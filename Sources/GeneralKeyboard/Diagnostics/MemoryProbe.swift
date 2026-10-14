//
//  MemoryProbe.swift
//  GeneralKeyboard
//
//  Phase 1B instrumentation. Apple publishes no memory limit for keyboard
//  extensions — the widely quoted "48 MB" traces back to a jailbreak plist
//  for a 1 GB iPhone 6, and Apple DTS has stated on the record that the
//  limits are undocumented and change between releases. So the only way to
//  know our headroom is to measure it on real devices.
//
//  This file compiles to nothing in Release. It reports `phys_footprint`,
//  the same number jetsam judges a process by — not `resident_size`, which
//  overstates by counting shared pages.
//
//  Read it live without Xcode (the debugger extends extension lifetime and
//  masks exactly the teardown behavior we want to observe):
//    log stream --predicate 'subsystem == "<keyboard extension bundle id>"' | grep kb-mem
//

#if DEBUG
import Foundation
import os.log

enum MemoryProbe {

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier
            ?? KeyboardDefinition.current.data.diagnosticsSubsystem,
        category: "kb-mem")

    /// Highest footprint seen in this process, so a spike that is released
    /// before the next sample still shows up in the log.
    private static var peakBytes: UInt64 = 0

    /// Footprint in bytes, or nil if the kernel call fails.
    static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return UInt64(info.phys_footprint)
    }

    /// Logs one sample with a stage label. Cheap enough to call from
    /// lifecycle hooks; never call it per keystroke.
    static func log(_ stage: String) {
        guard let bytes = footprint() else {
            logger.log("[kb-mem] \(stage, privacy: .public) — footprint unavailable")
            return
        }
        peakBytes = max(peakBytes, bytes)
        let mb = Double(bytes) / 1_048_576
        let peakMB = Double(peakBytes) / 1_048_576
        logger.log("[kb-mem] \(stage, privacy: .public) footprint=\(String(format: "%.1f", mb), privacy: .public)MB peak=\(String(format: "%.1f", peakMB), privacy: .public)MB")
    }
}
#endif
