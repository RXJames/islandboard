/*
 * IslandBoard (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */


#if os(macOS)
import XCTest
@testable import IslandBoard

final class SystemMonitorCoreTests: XCTestCase {

    // MARK: - CPU

    private func ticks(_ user: UInt32, _ system: UInt32, _ idle: UInt32, _ nice: UInt32 = 0) -> CPUUsageCalculator.CoreTicks {
        CPUUsageCalculator.CoreTicks(user: user, system: system, idle: idle, nice: nice)
    }

    func testCPUUsageCalculator() {
        let previous = [ticks(10, 10, 80)]
        let current = [ticks(20, 20, 160)]
        let breakdown = CPUUsageCalculator.calculate(previous: previous, current: current)
        XCTAssertNotNil(breakdown)
        XCTAssertEqual(breakdown?.usage ?? -1, 20, accuracy: 0.001)
        XCTAssertEqual(breakdown?.user ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(breakdown?.system ?? -1, 10, accuracy: 0.001)
        XCTAssertEqual(breakdown?.idle ?? -1, 80, accuracy: 0.001)
        XCTAssertEqual(breakdown?.perCore.first ?? -1, 20, accuracy: 0.001)
    }

    func testCPUUsageCalculatorHandlesTickWrap() {
        let previous = [ticks(UInt32.max - 4, 0, 0)]
        let current = [ticks(5, 0, 0)]
        let breakdown = CPUUsageCalculator.calculate(previous: previous, current: current)
        XCTAssertEqual(breakdown?.usage ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(breakdown?.perCore.first ?? -1, 100, accuracy: 0.001)
    }

    func testCPUUsageCalculatorRequiresMatchingTopology() {
        XCTAssertNil(CPUUsageCalculator.calculate(previous: nil, current: [ticks(1, 1, 1)]))
        XCTAssertNil(CPUUsageCalculator.calculate(previous: [ticks(1, 1, 1)], current: []))
        XCTAssertNil(CPUUsageCalculator.calculate(
            previous: [ticks(1, 1, 1)],
            current: [ticks(1, 1, 1), ticks(1, 1, 1)]
        ))
    }

    // MARK: - Memory

    func testMemoryCalculatorMatchesSwiftSemantics() {
        let result = MemoryUsageCalculator.compute(
            totalBytes: 100,
            activeBytes: 30,
            inactiveBytes: 10,
            speculativeBytes: 5,
            wiredBytes: 20,
            compressedBytes: 5,
            purgeableBytes: 2,
            externalBytes: 3
        )
        XCTAssertEqual(result.usedBytes, 65)
        XCTAssertEqual(result.appBytes, 40)
        XCTAssertEqual(result.cacheBytes, 5)
        XCTAssertEqual(result.freeBytes, 35)
        XCTAssertEqual(result.usagePercent, 65, accuracy: 0.001)
    }

    func testMemoryCalculatorClampsToTotal() {
        let result = MemoryUsageCalculator.compute(
            totalBytes: 50,
            activeBytes: 40,
            inactiveBytes: 40,
            speculativeBytes: 40,
            wiredBytes: 40,
            compressedBytes: 40,
            purgeableBytes: 0,
            externalBytes: 0
        )
        XCTAssertEqual(result.usedBytes, 50)
        XCTAssertEqual(result.freeBytes, 0)
        XCTAssertEqual(result.appBytes, 0)
    }

    func testMemoryPressureMapping() {
        XCTAssertEqual(MemoryUsageCalculator.pressure(from: 0).level, .normal)
        XCTAssertEqual(MemoryUsageCalculator.pressure(from: 2).level, .warning)
        XCTAssertEqual(MemoryUsageCalculator.pressure(from: 4).level, .critical)
    }

    // MARK: - Network

    func testNetworkDeltaHandlesWrapAndReset() {
        XCTAssertEqual(NetworkRateCalculator.delta(current: 200, previous: 100), 100)
        XCTAssertEqual(
            NetworkRateCalculator.delta(current: 5, previous: UInt32.max - 9),
            15
        )
        XCTAssertEqual(NetworkRateCalculator.delta(current: 200, previous: 1_000), 200)
    }

    func testNetworkRate() {
        XCTAssertEqual(NetworkRateCalculator.rate(delta: 1_000, elapsed: 2), 500, accuracy: 0.001)
        XCTAssertEqual(NetworkRateCalculator.rate(delta: 1_000, elapsed: 0), 0)
        XCTAssertEqual(NetworkRateCalculator.rate(delta: 1_000, elapsed: -1), 0)
    }

    // MARK: - Disk

    func testDiskUsageAndRate() {
        XCTAssertEqual(DiskUsageCalculator.usagePercent(total: 100, free: 25), 75, accuracy: 0.001)
        XCTAssertEqual(DiskUsageCalculator.usagePercent(total: 0, free: 0), 0)
        XCTAssertEqual(DiskUsageCalculator.rate(delta: 2_048, elapsed: 2), 1_024, accuracy: 0.001)
        XCTAssertEqual(DiskUsageCalculator.rate(delta: 2_048, elapsed: 0), 0)
    }

    // MARK: - Processes / thermal

    func testProcessCPUPercentAndStates() {
        XCTAssertEqual(ProcessCPUCalculator.percent(cpuTimeNs: 500_000_000, wallTime: 1) ?? -1, 50, accuracy: 0.001)
        XCTAssertNil(ProcessCPUCalculator.percent(cpuTimeNs: 0, wallTime: 1))
        XCTAssertNil(ProcessCPUCalculator.percent(cpuTimeNs: 1, wallTime: 0))
        XCTAssertEqual(ProcessCPUCalculator.stateName(1), "idle")
        XCTAssertEqual(ProcessCPUCalculator.stateName(2), "running")
        XCTAssertEqual(ProcessCPUCalculator.stateName(3), "sleeping")
        XCTAssertEqual(ProcessCPUCalculator.stateName(4), "stopped")
        XCTAssertEqual(ProcessCPUCalculator.stateName(5), "zombie")
        XCTAssertEqual(ProcessCPUCalculator.stateName(99), "unknown")
    }

    func testThermalLevelMapping() {
        XCTAssertEqual(ThermalLevel(.nominal), .nominal)
        XCTAssertEqual(ThermalLevel(.fair), .fair)
        XCTAssertEqual(ThermalLevel(.serious), .serious)
        XCTAssertEqual(ThermalLevel(.critical), .critical)
    }

    func testDataStoreTracksDiskAndGPUHistory() {
        var store = MonitorDataStore(historyLimit: 4)
        guard case .disk(let disk) = store.record(.disk(diskStats(read: 10, write: 20))) else {
            return XCTFail("expected disk sample")
        }
        XCTAssertEqual(disk.historyRead, [10])
        XCTAssertEqual(disk.historyWrite, [20])

        guard case .gpu(let gpu) = store.record(.gpu(gpuStats(utilization: 40))) else {
            return XCTFail("expected GPU sample")
        }
        XCTAssertEqual(gpu.history, [40])
    }

    // MARK: - History

    func testHistoryRingIsBounded() {
        var history = MonitorHistory(capacity: 120)
        for value in 0..<200 {
            history.append(Double(value))
        }
        XCTAssertEqual(history.values.count, 120)
        XCTAssertEqual(history.values.first, 80)
        XCTAssertEqual(history.values.last, 199)
        XCTAssertEqual(history.latest, 199)
    }

    func testHistoryIgnoresNonFiniteValues() {
        var history = MonitorHistory(capacity: 4)
        history.append(.nan)
        history.append(.infinity)
        history.append(1)
        XCTAssertEqual(history.values, [1])
    }

    func testDataStoreSkipsWarmupAndKeepsLatestHistory() {
        var store = MonitorDataStore(historyLimit: 3)
        _ = store.record(.cpu(cpu(usage: 10, warming: true)))
        _ = store.record(.cpu(cpu(usage: 20, warming: false)))
        guard case .cpu(let stats) = store.record(.cpu(cpu(usage: 30, warming: false))) else {
            return XCTFail("expected CPU sample")
        }
        XCTAssertEqual(stats.history, [20, 30])
    }

    // MARK: - Availability and scheduling

    func testMetricAvailabilityStates() {
        XCTAssertTrue(MetricAvailability.available.isAvailable)
        XCTAssertFalse(MetricAvailability.unavailable(reason: "no sensor").isAvailable)
        XCTAssertFalse(MetricAvailability.permissionRestricted.isAvailable)
        XCTAssertFalse(MetricAvailability.stale(reason: "hidden").isAvailable)
        XCTAssertEqual(MetricAvailability.permissionRestricted.displayText, "Permission required")
        XCTAssertEqual(MetricAvailability.unavailable(reason: "no sensor").displayText, "no sensor")
    }

    func testSchedulerDueDomains() {
        let now: TimeInterval = 10
        let intervals: [MonitorDomain: TimeInterval] = [.cpu: 1, .memory: 2, .network: 1]
        let domains: Set<MonitorDomain> = [.cpu, .memory, .network]

        // First tick: everything is due.
        XCTAssertEqual(
            Set(MonitorScheduler.dueDomains(now: now, lastRun: [:], intervals: intervals, domains: domains)),
            domains
        )

        // Only the domains whose interval elapsed.
        let lastRun: [MonitorDomain: TimeInterval] = [.cpu: 9.5, .memory: 7.5, .network: 9.5]
        XCTAssertEqual(
            MonitorScheduler.dueDomains(now: now, lastRun: lastRun, intervals: intervals, domains: domains),
            [.memory]
        )
    }

    func testSurfaceDomainPolicy() {
        XCTAssertTrue(SystemMonitorService.domains(for: []).isEmpty)
        XCTAssertEqual(
            SystemMonitorService.domains(for: [.notch]),
            [.cpu, .memory, .network, .disk, .gpu, .thermal]
        )
        XCTAssertTrue(
            SystemMonitorService.domains(for: [.dashboard(showProcesses: true)]).contains(.processes)
        )
        XCTAssertFalse(
            SystemMonitorService.domains(for: [.dashboard(showProcesses: false)]).contains(.processes)
        )
    }

    // MARK: - Live smoke test

    @MainActor
    func testLiveCollectorsProduceData() async throws {
        var configuration = MonitorConfiguration.default
        configuration.cpuInterval = 0.25
        configuration.memoryInterval = 0.5
        configuration.networkInterval = 0.25
        configuration.diskInterval = 0.25
        configuration.gpuInterval = 0.5
        configuration.thermalInterval = 0.5
        configuration.processInterval = 0.5
        configuration.tickInterval = 0.1

        let service = SystemMonitorService(configuration: configuration)
        service.setSurface(.dashboard(showProcesses: true), visible: true)
        defer { service.setSurface(.dashboard(showProcesses: true), visible: false) }

        try await Task.sleep(nanoseconds: 1_400_000_000)

        XCTAssertEqual(service.cpu?.availability, .available)
        XCTAssertGreaterThan(service.cpu?.perCore.count ?? 0, 0)
        XCTAssertNotNil(service.memory)
        XCTAssertGreaterThan(service.memory?.totalBytes ?? 0, 0)
        XCTAssertLessThanOrEqual(
            service.memory?.usedBytes ?? .max,
            service.memory?.totalBytes ?? 0
        )
        XCTAssertEqual(service.network?.availability, .available)

        XCTAssertEqual(service.disk?.availability, .available)
        XCTAssertGreaterThan(service.disk?.volumes.count ?? 0, 0)
        XCTAssertEqual(service.disk?.ioAvailability, .available)

        XCTAssertNotNil(service.gpu)
        XCTAssertGreaterThan(service.gpu?.devices.count ?? 0, 0)

        XCTAssertEqual(service.thermal?.availability, .available)
        XCTAssertNotEqual(service.thermal?.level, .unknown)

        XCTAssertEqual(service.processes?.availability, .available)
        XCTAssertGreaterThan(service.processes?.total ?? 0, 10)
    }

    /// Verifies that rusage CPU ticks are converted with the mach timebase:
    /// a busy loop on this thread must register as roughly one core.
    func testLiveProcessCPUUnits() throws {
        let collector = ProcessCollector()
        _ = collector.collect()

        let start = DispatchTime.now()
        var value: UInt64 = 0
        while DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds < 400_000_000 {
            value = value &* 6364136223846793005 &+ 1
        }
        _ = value

        let snapshot = collector.collect()
        let selfEntry = snapshot.items.first { $0.pid == getpid() }
        XCTAssertNotNil(selfEntry)
        XCTAssertGreaterThan(selfEntry?.memoryBytes ?? 0, 0)
        XCTAssertGreaterThan(selfEntry?.cpuPercent ?? 0, 20)
        XCTAssertFalse(selfEntry?.restricted ?? true)
    }

    func testProbeSMCTemperatureKeysTemporary() {
        let groups: [(String, [String])] = [
            ("GPU", ["Tg05", "Tg0D", "Tg0L", "Tg0P", "Tg0T", "Tg0f", "Tg0e", "Tg0j", "Tg0k", "Tg0y", "Tg0S", "Tg0U", "Tg0V", "Tg0W", "Tg0X", "Tg0Z", "Tg1f", "Tg1e", "Tg1j", "Tg1L", "Tg1P", "Tg1T"]),
            ("MEM", ["Tm00", "Tm01", "Tm02", "Tm0P", "Tm0p", "Tm0C", "Tm0D", "Tm0E", "Tm0F", "Tm0G", "Tm0H", "Tm0K", "Tm0L", "Tm0M", "Tm0N", "Tm0O", "Tm0Q", "Tm0R", "Tm0S", "Tm0T", "Tm0U", "Tm0V", "Tm0W", "Tm0X", "Tm0Y", "Tm0Z", "Tm1P", "Tm1p"]),
            ("DISK", ["TH0x", "TH0P", "TH0p", "TH0D", "TH0d", "TH0E", "TH0e", "TH0F", "TH0f", "TH0G", "TH0g", "TH0H", "TH0h", "TH0J", "TH0j", "TH0K", "TH0k", "TH0L", "TH0l", "TH0M", "TH0m", "TH0N", "TH0n", "TH0O", "TH0o", "TH0Q", "TH0q", "TH0R", "TH0r", "TH0S", "TH0s", "TH0T", "TH0t", "TH0U", "TH0u", "TH0V", "TH0v", "TH0W", "TH0w", "TH0X", "TH0x", "TH0Y", "TH0y", "TH0Z", "TH0z", "Ts0P", "Ts0p", "Ts0S", "Ts0s", "Ts0T", "Ts0t", "Ts0U", "Ts0u", "Ts0V", "Ts0v", "Ts0W", "Ts0w", "Ts0X", "Ts0x", "Ts0Y", "Ts0y", "Ts0Z", "Ts0z", "TB0T", "TB1T", "TB2T"]),
            ("CPU", ["Tp00", "Tp04", "Tp08", "Tp0C", "Tp0G", "Tp0K", "Tp0O", "Tp0R", "Tp0U", "Tp0X", "Tp0a", "Tp0d", "Tp0g", "Tp0j", "Tp0m", "Tp0p", "Tp0u", "Tp0y", "TC0D", "TC0E", "TC0F", "TC0P", "TC0H"])
        ]
        for (label, keys) in groups {
            let hits = keys.compactMap { key -> String? in
                guard let value = SMC.shared.getValue(key), value > 0, value < 120 else { return nil }
                return "\(key)=\(String(format: "%.2f", value))"
            }
            print("SMC \(label): \(hits)")
        }
    }

    func testThermalSensorsHaveExpectedKinds() {
        let stats = ThermalCollector().collect()
        XCTAssertEqual(stats.sensors.map(\.kind), [.cpu, .gpu, .memory, .disk])
        XCTAssertEqual(stats.sensors.count, 4)
        for reading in stats.sensors {
            if let celsius = reading.celsius {
                XCTAssertGreaterThan(celsius, 0)
                XCTAssertLessThan(celsius, 120)
            }
        }
        XCTAssertNotNil(stats.sensors.first(where: { $0.kind == .cpu })?.celsius)
        XCTAssertEqual(stats.cpuTemperatureCelsius, stats.sensors.first(where: { $0.kind == .cpu })?.celsius)
    }

    // MARK: - Helpers

    private func diskStats(read: Double, write: Double) -> DiskStats {
        DiskStats(
            availability: .available,
            ioAvailability: .available,
            sampledAt: Date(),
            isWarmingUp: false,
            volumes: [],
            readBytesPerSecond: read,
            writeBytesPerSecond: write,
            totalReadBytes: 1,
            totalWrittenBytes: 2,
            historyRead: [],
            historyWrite: []
        )
    }

    private func gpuStats(utilization: Double?) -> GPUStats {
        GPUStats(
            availability: .available,
            sampledAt: Date(),
            totalUtilization: utilization,
            devices: [],
            history: []
        )
    }

    private func cpu(usage: Double, warming: Bool) -> CPUStats {
        CPUStats(
            availability: .available,
            sampledAt: Date(),
            isWarmingUp: warming,
            totalUsage: usage,
            userPercent: usage,
            systemPercent: 0,
            idlePercent: 100 - usage,
            perCore: [usage],
            loadAverage: nil,
            uptime: nil,
            history: []
        )
    }
}
#endif
