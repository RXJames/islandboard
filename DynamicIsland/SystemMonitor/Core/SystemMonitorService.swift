import AppKit
import Foundation
import Observation

/// The single Swift entry point for system monitoring. The notch overview and
/// the dashboard both register visibility here; collectors and their
/// previous-counter state live in `MonitorEngine` (an actor) and never run on
/// the main thread.
@MainActor
@Observable
final class SystemMonitorService {
    static let shared = SystemMonitorService()

    private(set) var cpu: CPUStats?
    private(set) var memory: MemoryStats?
    private(set) var network: NetworkStats?
    private(set) var disk: DiskStats?
    private(set) var gpu: GPUStats?
    private(set) var thermal: ThermalStats?
    private(set) var processes: ProcessStatsSnapshot?
    private(set) var isRunning = false

    private let configuration: MonitorConfiguration
    private let engine: MonitorEngine
    private let scheduler = MonitorScheduler()
    private var history: MonitorDataStore
    private var surfaces: Set<MonitorSurface> = []
    private var dashboardProcessesVisible = false
    private var inFlight: Set<MonitorDomain> = []
    nonisolated private let workspaceCenter: NotificationCenter
    @ObservationIgnored nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?

    /// Domains that have collectors in this phase. GPU/thermal/disk/process
    /// are added incrementally and are not scheduled until then.
    private static let implementedDomains: Set<MonitorDomain> = [.cpu, .memory, .network, .disk, .gpu, .thermal, .processes]

    init(configuration: MonitorConfiguration = .default) {
        let sanitized = configuration.sanitized()
        self.configuration = sanitized
        self.engine = MonitorEngine(configuration: sanitized)
        self.history = MonitorDataStore(historyLimit: sanitized.historyLimit)
        let center = NSWorkspace.shared.notificationCenter
        self.workspaceCenter = center
        self.wakeObserver = center.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWake()
            }
        }
    }

    deinit {
        if let wakeObserver {
            workspaceCenter.removeObserver(wakeObserver)
        }
    }

    var snapshot: MonitorSnapshot {
        MonitorSnapshot(
            cpu: cpu,
            memory: memory,
            network: network,
            disk: disk,
            gpu: gpu,
            thermal: thermal,
            processes: processes,
            sampledAt: Date()
        )
    }

    var activeDomains: Set<MonitorDomain> {
        Self.domains(for: surfaces)
    }

    /// Register/unregister a visible surface. The scheduler starts on the
    /// first surface and stops when the last one disappears.
    func setSurface(_ surface: MonitorSurface, visible: Bool) {
        if visible {
            surfaces.insert(surface)
        } else {
            surfaces.remove(surface)
        }
        syncScheduler()
    }

    /// Show/hide the dashboard while preserving whether the Processes page is
    /// selected (used by the window controller's occlusion handling).
    func setDashboardVisible(_ visible: Bool) {
        surfaces.remove(.dashboard(showProcesses: true))
        surfaces.remove(.dashboard(showProcesses: false))
        if visible {
            surfaces.insert(.dashboard(showProcesses: dashboardProcessesVisible))
        }
        syncScheduler()
    }

    /// The dashboard's current sidebar page decides whether the (relatively
    /// expensive) process table is sampled. No-op when the dashboard is not
    /// visible.
    func setDashboardProcessesVisible(_ visible: Bool) {
        dashboardProcessesVisible = visible
        guard surfaces.contains(where: { surface in
            if case .dashboard = surface { return true }
            return false
        }) else { return }
        surfaces.remove(.dashboard(showProcesses: true))
        surfaces.remove(.dashboard(showProcesses: false))
        surfaces.insert(.dashboard(showProcesses: visible))
        syncScheduler()
    }

    func stop() {
        scheduler.stop()
        isRunning = false
        inFlight.removeAll()
    }

    private func syncScheduler() {
        let domains = Self.domains(for: surfaces).intersection(Self.implementedDomains)
        guard !domains.isEmpty else {
            stop()
            return
        }
        scheduler.start(domains: domains, configuration: configuration) { [weak self] domain in
            self?.request(domain)
        }
        isRunning = true
    }

    private func request(_ domain: MonitorDomain) {
        guard !inFlight.contains(domain) else { return }
        inFlight.insert(domain)
        Task { [weak self] in
            guard let self else { return }
            let sample = await self.engine.sample(domain)
            self.apply(sample)
        }
    }

    private func apply(_ sample: DomainSample) {
        inFlight.remove(sample.domain)
        switch history.record(sample) {
        case .cpu(let stats):
            cpu = stats
        case .memory(let stats):
            memory = stats
        case .network(let stats):
            network = stats
        case .disk(let stats):
            disk = stats
        case .gpu(let stats):
            gpu = stats
        case .thermal(let stats):
            thermal = stats
        case .processes(let stats):
            processes = stats
        case .unavailable:
            break
        }
    }

    private func handleWake() {
        Task { [weak self] in
            guard let self else { return }
            await self.engine.resetBaselines()
            self.scheduler.reschedule()
        }
    }

    nonisolated static func domains(for surfaces: Set<MonitorSurface>) -> Set<MonitorDomain> {
        guard !surfaces.isEmpty else { return [] }
        var result: Set<MonitorDomain> = [.cpu, .memory, .network, .disk, .gpu, .thermal]
        for surface in surfaces {
            if case .dashboard(showProcesses: true) = surface {
                result.insert(.processes)
            }
        }
        return result
    }
}
