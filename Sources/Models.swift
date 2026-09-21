import Foundation
import AppKit

// Low-level process information via libproc. No public Swift API exists for
// per-process task/rusage data — these private C symbols are stable and are
// what Activity Monitor / nettop use under the hood.

let PROC_PIDTASKINFO: Int32 = 4
let RUSAGE_INFO_V2: Int32 = 2

struct ProcTaskInfo {
    var pti_virtual_size: UInt64 = 0
    var pti_resident_size: UInt64 = 0
    var pti_total_user: UInt64 = 0
    var pti_total_system: UInt64 = 0
    var pti_threads_user: UInt64 = 0
    var pti_threads_system: UInt64 = 0
    var pti_policy: Int32 = 0
    var pti_faults: Int32 = 0
    var pti_pageins: Int32 = 0
    var pti_cow_faults: Int32 = 0
    var pti_messages_sent: Int32 = 0
    var pti_messages_received: Int32 = 0
    var pti_syscalls_mach: Int32 = 0
    var pti_syscalls_unix: Int32 = 0
    var pti_csw: Int32 = 0
    var pti_threadnum: Int32 = 0
    var pti_numrunning: Int32 = 0
    var pti_priority: Int32 = 0
}

@_silgen_name("proc_pidinfo")
func proc_pidinfo(_ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?, _ buffersize: Int32) -> Int32

@_silgen_name("proc_pid_rusage")
func proc_pid_rusage(_ pid: Int32, _ flavor: Int32, _ buffer: UnsafeMutableRawPointer?) -> Int32

// MARK: - Domain models

struct AppEntry: Identifiable {
    let id: String          // bundle id, fallback path
    let name: String
    let icon: NSImage?
    let url: URL?           // .app bundle URL for launch
    let pid: pid_t?
    let launchDate: Date?
    var isRunning: Bool { pid != nil }
}

struct UsageSnapshot {
    var cpu: Double = 0
    var memMB: Double = 0
    var info = ProcTaskInfo()
    var diskReadMB: Double = 0
    var diskWriteMB: Double = 0
    var netInMB: Double = 0
    var netOutMB: Double = 0
}

struct AlertRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var appID: String        // bundle id, or "any"
    var appName: String
    var threshold: Double    // CPU %
    var durationSeconds: Int // consecutive seconds above threshold
    var enabled: Bool = true
}
