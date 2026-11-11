import Darwin
import Foundation

/// Thin wrappers around the Mach calls used by the CPU and memory collectors.
/// No state is kept here; collectors own their previous snapshots.
enum MachSupport {
    static var pageSize: UInt64 {
        UInt64(vm_kernel_page_size)
    }

    static func processorTicks() -> [CPUUsageCalculator.CoreTicks]? {
        var cpuInfo: processor_info_array_t?
        var cpuCount: natural_t = 0
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &cpuCount,
            &cpuInfo,
            &infoCount
        )
        guard result == KERN_SUCCESS, let cpuInfo, cpuCount > 0 else {
            return nil
        }

        // host_processor_info allocates with vm_allocate; release immediately
        // after copying — no need to retain the Mach buffer between samples.
        defer {
            let size = vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), size)
        }

        let stateMax = Int(CPU_STATE_MAX)
        var ticks: [CPUUsageCalculator.CoreTicks] = []
        ticks.reserveCapacity(Int(cpuCount))
        for cpu in 0..<Int(cpuCount) {
            let base = cpu * stateMax
            ticks.append(
                CPUUsageCalculator.CoreTicks(
                    user: UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_USER)]),
                    system: UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_SYSTEM)]),
                    idle: UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_IDLE)]),
                    nice: UInt32(bitPattern: cpuInfo[base + Int(CPU_STATE_NICE)])
                )
            )
        }
        return ticks
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.denom != 0 else {
            return mach_timebase_info_data_t(numer: 1, denom: 1)
        }
        return info
    }()

    /// `proc_taskinfo`/`rusage` CPU times are mach absolute ticks, not
    /// nanoseconds. On Apple silicon the timebase is 24 MHz, so treating the
    /// ticks as nanoseconds under-reports CPU by ~42×.
    static func nanoseconds(fromTicks ticks: UInt64) -> Double {
        Double(ticks) * Double(timebase.numer) / Double(timebase.denom)
    }

    static func vmStatistics() -> vm_statistics64? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }
}
