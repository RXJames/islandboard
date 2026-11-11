import Foundation

/// One run-loop timer drives every domain. Each tick checks which domains are
/// due, so adding metrics never adds timers. The timer exists only while a
/// surface is visible; `stop()` tears it down completely.
@MainActor
final class MonitorScheduler {
    private var timer: Timer?
    private var domains: Set<MonitorDomain> = []
    private var intervals: [MonitorDomain: TimeInterval] = [:]
    private var lastRun: [MonitorDomain: TimeInterval] = [:]
    private var onDue: ((MonitorDomain) -> Void)?
    private(set) var isRunning = false

    func start(
        domains: Set<MonitorDomain>,
        configuration: MonitorConfiguration,
        onDue: @escaping (MonitorDomain) -> Void
    ) {
        guard !domains.isEmpty else {
            stop()
            return
        }

        self.onDue = onDue
        self.domains = domains
        self.intervals = Dictionary(
            uniqueKeysWithValues: domains.map { ($0, configuration.interval(for: $0)) }
        )

        if timer == nil {
            let timer = Timer(timeInterval: configuration.tickInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.tick()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        if !isRunning {
            lastRun.removeAll()
            isRunning = true
        }
        tick()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
        domains = []
        intervals = [:]
        lastRun = [:]
        onDue = nil
    }

    /// Sample everything immediately (wake / surface reappears) instead of
    /// waiting for the next interval.
    func reschedule() {
        guard isRunning else { return }
        lastRun.removeAll()
        tick()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        let due = Self.dueDomains(now: now, lastRun: lastRun, intervals: intervals, domains: domains)
        for domain in due {
            lastRun[domain] = now
            onDue?(domain)
        }
    }

    /// Pure scheduling decision, unit-tested without a run loop.
    nonisolated static func dueDomains(
        now: TimeInterval,
        lastRun: [MonitorDomain: TimeInterval],
        intervals: [MonitorDomain: TimeInterval],
        domains: Set<MonitorDomain>
    ) -> [MonitorDomain] {
        domains
            .filter { domain in
                guard let interval = intervals[domain], interval > 0 else { return false }
                guard let last = lastRun[domain] else { return true }
                return now - last >= interval - 0.05
            }
            .sorted { $0.rawValue < $1.rawValue }
    }
}
