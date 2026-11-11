import SwiftUI

enum ProcessSortKey: String, CaseIterable, Identifiable {
    case cpu
    case memory
    case name
    case pid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        case .name: return "Name"
        case .pid: return "PID"
        }
    }
}

struct ProcessesSection: View {
    let service: SystemMonitorService

    @State private var searchText = ""
    @State private var sortKey: ProcessSortKey = .cpu
    @State private var descending = true

    private var snapshot: ProcessStatsSnapshot? { service.processes }

    private var filteredItems: [ProcessEntryStats] {
        var items = snapshot?.items ?? []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty {
            items = items.filter { row in
                row.name.localizedCaseInsensitiveContains(query)
                    || String(row.pid).contains(query)
                    || (row.user?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }
        return items.sorted { lhs, rhs in
            let order = compare(lhs, rhs)
            if order == .orderedSame {
                return lhs.pid < rhs.pid
            }
            return descending ? order == .orderedDescending : order == .orderedAscending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            controls

            if let snapshot, snapshot.availability.isAvailable {
                if filteredItems.isEmpty {
                    MonitorEmptyState(
                        icon: "magnifyingglass",
                        title: searchText.isEmpty ? "No processes" : "No matches",
                        message: searchText.isEmpty
                            ? "proc_listpids returned an empty table."
                            : "Try a different name, user, or PID."
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    processTable
                }
                footer(snapshot)
            } else if let snapshot {
                MonitorEmptyState(
                    icon: "list.bullet.rectangle",
                    title: "Process list unavailable",
                    message: snapshot.availability.displayText ?? "proc_listpids failed."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MonitorEmptyState(
                    icon: "list.bullet.rectangle",
                    title: "Collecting processes",
                    message: "The table is sampled every 3 seconds while this page is visible."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            service.setDashboardProcessesVisible(true)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Processes")
                .font(.system(size: 22, weight: .semibold))
            Text("Read-only libproc table · CPU is normalised to one logical core")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search name, user, or PID", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
            )
            .frame(width: 280)

            Picker("Sort", selection: $sortKey) {
                ForEach(ProcessSortKey.allCases) { key in
                    Text(key.title).tag(key)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 130)

            Button {
                descending.toggle()
            } label: {
                Image(systemName: descending ? "arrow.down" : "arrow.up")
            }
            .buttonStyle(.bordered)
            .help(descending ? "Descending" : "Ascending")

            Spacer()

            if let snapshot {
                Text("\(snapshot.total) processes · \(snapshot.restricted) restricted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var processTable: some View {
        Table(filteredItems) {
            TableColumn("Process") { row in
                HStack(spacing: 6) {
                    if row.restricted {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(Color.orange)
                            .help("CPU/memory restricted")
                    } else {
                        Circle()
                            .fill(Color.secondary.opacity(0.4))
                            .frame(width: 5, height: 5)
                    }
                    Text(row.name)
                        .lineLimit(1)
                }
            }
            .width(min: 220, ideal: 320)

            TableColumn("PID") { row in
                Text(String(row.pid))
                    .monospacedDigit()
            }
            .width(70)

            TableColumn("User") { row in
                Text(row.user ?? "—")
                    .lineLimit(1)
            }
            .width(120)

            TableColumn("CPU") { row in
                HStack {
                    Spacer()
                    Text(row.cpuPercent.map { MonitorFormat.percent($0) } ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(row.cpuPercent == nil ? Color.secondary : Color.primary)
                }
            }
            .width(80)

            TableColumn("Memory") { row in
                HStack {
                    Spacer()
                    Text(MonitorFormat.bytes(row.memoryBytes))
                        .monospacedDigit()
                }
            }
            .width(100)

            TableColumn("State") { row in
                Text(row.state)
                    .foregroundStyle(.secondary)
            }
            .width(90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func footer(_ snapshot: ProcessStatsSnapshot) -> some View {
        HStack(spacing: 8) {
            Text("Sampled \(snapshot.sampledAt.formatted(date: .omitted, time: .standard))")
            Text("·")
            Text("\(filteredItems.count) shown")
            Spacer()
            if snapshot.restricted > 0 {
                Label("Locked rows lack CPU/memory permission", systemImage: "lock.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }

    private func compare(_ lhs: ProcessEntryStats, _ rhs: ProcessEntryStats) -> ComparisonResult {
        let result: ComparisonResult
        switch sortKey {
        case .cpu:
            result = compareValues(lhs.cpuPercent ?? -1, rhs.cpuPercent ?? -1)
        case .memory:
            result = compareValues(Double(lhs.memoryBytes ?? 0), Double(rhs.memoryBytes ?? 0))
        case .name:
            result = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        case .pid:
            result = compareValues(Double(lhs.pid), Double(rhs.pid))
        }
        return result
    }

    private func compareValues(_ lhs: Double, _ rhs: Double) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }
}
