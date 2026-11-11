import Darwin
import Foundation

/// Read-only process table via libproc. CPU/memory come from
/// `proc_pid_rusage` (public SDK); identity is guarded by
/// `ri_proc_start_abstime` so a recycled pid never inherits old CPU deltas.
/// Processes whose rusage is not readable stay listed with nil CPU/memory and
/// `restricted = true`.
final class ProcessCollector {
    private struct SampleState {
        var startAbstime: UInt64
        var cpuTicks: UInt64
        var atUptime: UInt64
    }

    private struct Metadata {
        var name: String?
        var uid: UInt32?
        var status: UInt32?
    }

    private var previous: [Int32: SampleState] = [:]
    private var userNames: [UInt32: String] = [:]
    private let maxSampleGap: TimeInterval

    init(maxSampleGap: TimeInterval = 10) {
        self.maxSampleGap = maxSampleGap
    }

    func collect() -> ProcessStatsSnapshot {
        let now = Date()
        let uptime = DispatchTime.now().uptimeNanoseconds

        guard let pids = Self.listPIDs() else {
            return ProcessStatsSnapshot(
                availability: .unavailable(reason: "proc_listpids failed"),
                sampledAt: now,
                total: 0,
                restricted: 0,
                items: []
            )
        }

        var entries: [ProcessEntryStats] = []
        entries.reserveCapacity(pids.count)
        var next: [Int32: SampleState] = [:]
        next.reserveCapacity(pids.count)
        var restrictedCount = 0

        for pid in pids {
            let metadata = Self.metadata(for: pid)
            let usage = Self.rusageInfo(pid)
            let name = metadata.name ?? "pid \(pid)"
            let user = metadata.uid.flatMap { userName(for: $0) }
            let state = ProcessCPUCalculator.stateName(metadata.status ?? 0)

            var cpuPercent: Double?
            var memoryBytes: UInt64?
            var restricted = true

            if let usage {
                restricted = false
                memoryBytes = usage.ri_phys_footprint
                let cpuTicks = usage.ri_user_time &+ usage.ri_system_time

                if let previousSample = previous[pid],
                   previousSample.startAbstime == usage.ri_proc_start_abstime {
                    let wallNanoseconds = uptime >= previousSample.atUptime
                        ? uptime - previousSample.atUptime
                        : 0
                    let wall = Double(wallNanoseconds) / 1_000_000_000
                    if wall > 0, wall <= maxSampleGap {
                        let deltaTicks = cpuTicks >= previousSample.cpuTicks
                            ? cpuTicks - previousSample.cpuTicks
                            : 0
                        let cpuTime = MachSupport.nanoseconds(fromTicks: deltaTicks)
                        cpuPercent = ProcessCPUCalculator.percent(cpuTimeNs: cpuTime, wallTime: wall)
                    }
                }

                next[pid] = SampleState(
                    startAbstime: usage.ri_proc_start_abstime,
                    cpuTicks: cpuTicks,
                    atUptime: uptime
                )
            } else {
                restrictedCount += 1
            }

            entries.append(
                ProcessEntryStats(
                    pid: pid,
                    name: name,
                    user: user,
                    uid: metadata.uid,
                    cpuPercent: cpuPercent,
                    memoryBytes: memoryBytes,
                    state: state,
                    restricted: restricted
                )
            )
        }

        entries.sort { $0.pid < $1.pid }
        previous = next

        return ProcessStatsSnapshot(
            availability: .available,
            sampledAt: now,
            total: entries.count,
            restricted: restrictedCount,
            items: entries
        )
    }

    func resetBaseline() {
        previous.removeAll()
    }

    // MARK: - libproc

    private static func listPIDs() -> [Int32]? {
        let requiredBytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard requiredBytes > 0 else { return nil }

        let capacity = Int(requiredBytes) / MemoryLayout<pid_t>.size + 32
        var pids = [pid_t](repeating: 0, count: capacity)
        let writtenBytes = pids.withUnsafeMutableBytes { buffer -> Int32 in
            proc_listpids(
                UInt32(PROC_ALL_PIDS),
                0,
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        guard writtenBytes > 0 else { return nil }

        let count = min(Int(writtenBytes) / MemoryLayout<pid_t>.size, pids.count)
        return pids.prefix(count).filter { $0 >= 0 }
    }

    private static func metadata(for pid: Int32) -> Metadata {
        let procName = processName(pid)

        if let info = bsdInfo(pid) {
            let name = procName
                ?? string(from: info.pbi_name)
                ?? string(from: info.pbi_comm)
            return Metadata(name: name, uid: info.pbi_uid, status: info.pbi_status)
        }

        if let info = shortBSDInfo(pid) {
            return Metadata(
                name: procName ?? pathName(pid) ?? string(from: info.pbsi_comm),
                uid: info.pbsi_uid,
                status: info.pbsi_status
            )
        }

        return Metadata(name: procName ?? pathName(pid), uid: nil, status: nil)
    }

    /// Executable basename via libproc. Used for root/other-user processes
    /// whose short BSD name is truncated to 16 characters.
    private static func pathName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let capacity = buffer.count
        let count = buffer.withUnsafeMutableBytes { raw -> Int32 in
            proc_pidpath(pid, raw.baseAddress, UInt32(capacity))
        }
        guard count > 0 else { return nil }
        let path = String(cString: buffer)
        return path.split(separator: "/").last.map(String.init)
    }

    private static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, UnsafeMutableRawPointer(pointer), size)
        }
        return result == size ? info : nil
    }

    private static func shortBSDInfo(_ pid: Int32) -> proc_bsdshortinfo? {
        var info = proc_bsdshortinfo()
        let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, UnsafeMutableRawPointer(pointer), size)
        }
        return result == size ? info : nil
    }

    private static func rusageInfo(_ pid: Int32) -> rusage_info_v6? {
        var info = rusage_info_v6()
        let result: Int32 = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pid_rusage(
                pid,
                RUSAGE_INFO_V6,
                UnsafeMutableRawPointer(pointer).assumingMemoryBound(to: rusage_info_t?.self)
            )
        }
        return result == 0 ? info : nil
    }

    private static func processName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let capacity = buffer.count
        let result = buffer.withUnsafeMutableBytes { raw -> Int32 in
            proc_name(pid, raw.baseAddress, UInt32(capacity))
        }
        guard result > 0 else { return nil }
        return String(cString: buffer)
    }

    /// C fixed-size char arrays import as tuples in Swift; read them as a
    /// bounded UTF-8 byte sequence instead of assuming array syntax.
    private static func string<T>(from field: T) -> String? {
        withUnsafeBytes(of: field) { raw in
            let bytes = raw.prefix { $0 != 0 }
            guard !bytes.isEmpty else { return nil }
            return String(bytes: bytes, encoding: .utf8)
        }
    }

    private func userName(for uid: UInt32) -> String? {
        if let cached = userNames[uid] {
            return cached
        }

        var passwdInfo = passwd()
        var buffer = [CChar](repeating: 0, count: 1024)
        var result: UnsafeMutablePointer<passwd>?
        let status = buffer.withUnsafeMutableBufferPointer { bufferPointer -> Int32 in
            withUnsafeMutablePointer(to: &passwdInfo) { passwdPointer in
                getpwuid_r(
                    uid,
                    passwdPointer,
                    bufferPointer.baseAddress,
                    bufferPointer.count,
                    &result
                )
            }
        }

        guard status == 0, let result, let namePointer = result.pointee.pw_name else {
            return nil
        }
        let name = String(cString: namePointer)
        userNames[uid] = name
        return name
    }
}
