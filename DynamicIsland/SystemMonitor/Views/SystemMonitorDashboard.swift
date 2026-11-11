import SwiftUI

enum MonitorSection: String, CaseIterable, Identifiable {
    case overview
    case cpu
    case memory
    case network
    case disk
    case gpu
    case thermal
    case processes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .network: return "Network"
        case .disk: return "Disk"
        case .gpu: return "GPU"
        case .thermal: return "Thermal"
        case .processes: return "Processes"
        }
    }

    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .cpu: return "cpu"
        case .memory: return "memorychip"
        case .network: return "network"
        case .disk: return "internaldrive"
        case .gpu: return "square.stack.3d.up"
        case .thermal: return "thermometer.medium"
        case .processes: return "list.bullet.rectangle"
        }
    }
}

struct SystemMonitorDashboard: View {
    @State private var service = SystemMonitorService.shared
    @State private var section: MonitorSection? = .overview

    private var selected: MonitorSection { section ?? .overview }

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                ForEach(MonitorSection.allCases) { item in
                    Label(item.title, systemImage: item.icon)
                        .tag(Optional(item))
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) {
                sidebarStatus
            }
        } detail: {
            detail
                .toolbar {
                    ToolbarItem(placement: .automatic) {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(service.isRunning ? Color.green : Color.secondary)
                                .frame(width: 6, height: 6)
                            Text(service.isRunning ? "Sampling" : "Paused")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            service.setDashboardProcessesVisible(selected == .processes)
        }
        .onChange(of: section) { _, newValue in
            service.setDashboardProcessesVisible((newValue ?? .overview) == .processes)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            service.setDashboardProcessesVisible(selected == .processes)
        }
    }

    private var sidebarStatus: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 6) {
                Circle()
                    .fill(service.isRunning ? Color.green : Color.secondary)
                    .frame(width: 6, height: 6)
                Text(service.isRunning ? "Sampling" : "Paused")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(service.activeDomains.count) metrics")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selected {
        case .overview:
            OverviewSection(service: service) { destination in
                section = destination
            }
        case .cpu:
            CPUSection(service: service)
        case .memory:
            MemorySection(service: service)
        case .network:
            NetworkSection(service: service)
        case .disk:
            DiskSection(service: service)
        case .gpu:
            GPUSection(service: service)
        case .thermal:
            ThermalSection(service: service)
        case .processes:
            ProcessesSection(service: service)
        }
    }
}
