import SwiftUI

struct NetworkSection: View {
    let service: SystemMonitorService

    var body: some View {
        MonitorSectionScaffold(
            "Network",
            subtitle: "Physical en* interfaces · counters are 32-bit wrap-safe"
        ) {
            if let network = service.network {
                if network.availability.isAvailable {
                HStack(spacing: 16) {
                    rateCard(
                        title: "Download",
                        icon: "arrow.down.circle.fill",
                        rate: network.downloadBytesPerSecond,
                        total: network.totalDownloadedBytes,
                        tint: MonitorPalette.network
                    )
                    rateCard(
                        title: "Upload",
                        icon: "arrow.up.circle.fill",
                        rate: network.uploadBytesPerSecond,
                        total: network.totalUploadedBytes,
                        tint: MonitorPalette.cpu
                    )
                }

                MonitorCard(title: "Throughput", icon: "chart.xyaxis.line", tint: MonitorPalette.network) {
                    MonitorHistoryChart(
                        primary: network.historyDownload,
                        secondary: network.historyUpload,
                        primaryTint: MonitorPalette.network,
                        secondaryTint: MonitorPalette.cpu,
                        primaryLabel: "Download",
                        secondaryLabel: "Upload",
                        height: 180
                    )
                }

                MonitorCard(
                    title: "Interfaces",
                    icon: "network",
                    tint: MonitorPalette.network,
                    subtitle: "\(network.interfaces.count) counted interfaces"
                ) {
                    if network.interfaces.isEmpty {
                        MonitorEmptyState(
                            icon: "network.slash",
                            title: "No active interfaces",
                            message: "No en* interface was returned by getifaddrs."
                        )
                    } else {
                        VStack(spacing: 0) {
                            ForEach(network.interfaces) { interface in
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(interface.isActive ? Color.green : Color.secondary)
                                        .frame(width: 6, height: 6)
                                    Text(interface.name)
                                        .font(.system(size: 12, weight: .medium).monospaced())
                                        .frame(width: 50, alignment: .leading)
                                    Text(interface.ipv4 ?? interface.ipv6 ?? "—")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("↓ \(MonitorFormat.rate(interface.downloadBytesPerSecond))")
                                        .font(.system(size: 11).monospacedDigit())
                                        .foregroundStyle(MonitorPalette.network)
                                    Text("↑ \(MonitorFormat.rate(interface.uploadBytesPerSecond))")
                                        .font(.system(size: 11).monospacedDigit())
                                        .foregroundStyle(MonitorPalette.cpu)
                                        .frame(width: 100, alignment: .trailing)
                                }
                                .padding(.vertical, 7)
                                if interface.id != network.interfaces.last?.id {
                                    Divider().opacity(0.5)
                                }
                            }
                        }
                    }
                }
                } else {
                    MonitorEmptyState(
                        icon: "network",
                        title: "Network unavailable",
                        message: network.availability.displayText ?? "getifaddrs failed"
                    )
                }
            } else {
                MonitorEmptyState(
                    icon: "network",
                    title: "Collecting network data",
                    message: "Speeds appear after the first counter interval."
                )
            }
        }
    }

    private func rateCard(title: String, icon: String, rate: Double, total: UInt64, tint: Color) -> some View {
        MonitorCard(title: title, icon: icon, tint: tint) {
            Text(MonitorFormat.rate(rate))
                .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(MonitorFormat.bytes(total)) since launch")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
