import Darwin
import Foundation

enum SysctlSupport {
    static func uint64(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        let result = name.withCString { pointer in
            sysctlbyname(pointer, &value, &size, nil, 0)
        }
        return result == 0 ? value : nil
    }

    static func int32(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let result = name.withCString { pointer in
            sysctlbyname(pointer, &value, &size, nil, 0)
        }
        return result == 0 ? value : nil
    }

    static func swapUsage() -> (total: UInt64, used: UInt64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        let result = "vm.swapusage".withCString { pointer in
            sysctlbyname(pointer, &usage, &size, nil, 0)
        }
        guard result == 0 else { return nil }
        return (UInt64(usage.xsu_total), UInt64(usage.xsu_used))
    }

    static func memoryPressureLevel() -> Int32? {
        int32("kern.memorystatus_vm_pressure_level")
    }

    static func loadAverage() -> LoadAverage? {
        var values = [Double](repeating: 0, count: 3)
        let result = values.withUnsafeMutableBufferPointer { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return 0 }
            return getloadavg(base, 3)
        }
        guard result == 3 else { return nil }
        return LoadAverage(oneMinute: values[0], fiveMinutes: values[1], fifteenMinutes: values[2])
    }

    static func uptime() -> TimeInterval? {
        var bootTime = timeval()
        var size = MemoryLayout<timeval>.size
        let result = "kern.boottime".withCString { pointer in
            sysctlbyname(pointer, &bootTime, &size, nil, 0)
        }
        guard result == 0, bootTime.tv_sec > 0 else { return nil }
        let boot = Double(bootTime.tv_sec) + Double(bootTime.tv_usec) / 1_000_000
        return max(0, Date().timeIntervalSince1970 - boot)
    }
}
