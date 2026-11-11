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

import SwiftUI
import Combine
import Darwin

/// A dense system-monitoring dashboard: six metric cards (CPU, GPU, memory,
/// disk, network, thermal), a per-core strip and a compact row for load /
/// processes / battery / uptime. Everything is a number plus an icon rather
/// than the graph-first Stats tab.
struct NotchSystemMonitorView: View {
    @EnvironmentObject private var vm: DynamicIslandViewModel
    @State private var monitor = SystemMonitorService.shared
    @State private var scrollSuppressionToken = UUID()

    @State private var batteryPercentage: Int?
    @State private var batteryCharging = false
    @State private var processCount = 0

    private let extras = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    LazyVGrid(columns: columns, spacing: 10) {
                        cpuCard
                        gpuCard
                        memoryCard
                        diskCard
                        networkCard
                        temperatureCard
                    }
                    coreStrip
                    compactRow
                }
                .padding(.bottom, 6)
            }
            .scrollEdgeClear()
            .modifier(MonitorScrollBottomGate { atBottom in
                // At the bottom (including rubber-band overscroll), let the
                // notch's close-scroll gesture through. Everywhere else the
                // monitor's own scrolling must not blur/dismiss the notch.
                vm.setScrollGestureSuppression(!atBottom, token: scrollSuppressionToken)
            })
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .environment(\.colorScheme, .dark)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            // The monitor page is taller than the base Home surface. Make the
            // hosting NSWindow follow the SwiftUI size as soon as this view is
            // installed, even if the tab-change observer was not attached yet.
            vm.refreshOpenNotchSizeForCurrentTab()
            // Until geometry reports otherwise, do not let a normal scroll
            // dismiss the notch. The geometry action releases this as soon as
            // the list is actually at its bottom edge.
            vm.setScrollGestureSuppression(true, token: scrollSuppressionToken)
            refreshExtras()
        }
        .onDisappear {
            vm.setScrollGestureSuppression(false, token: scrollSuppressionToken)
        }
        .onReceive(extras) { _ in refreshExtras() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 7) {
            Image(systemName: "speedometer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("System Monitor")
                .font(.system(size: 15, weight: .semibold))
            Circle()
                .fill(monitor.isRunning ? Color.green : Color.secondary)
                .frame(width: 5, height: 5)
            Text(monitor.isRunning ? "LIVE" : "IDLE")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            Spacer()
            Text("up \(uptimeText)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
            Button {
                SystemMonitorWindowController.shared.showWindow()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right.square")
                    Text("Open Dashboard")
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(Color.accentColor.opacity(0.14))
                )
                .overlay(
                    Capsule().strokeBorder(Color.accentColor.opacity(0.28), lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)
            .help("Open System Monitor dashboard")
            .accessibilityLabel("Open System Monitor dashboard")
        }
        .frame(height: 22)
    }

    // MARK: Cards

    private var cpuCard: some View {
        let cpu = monitor.cpu
        let warming = cpu?.isWarmingUp ?? true
        let available = cpu?.availability.isAvailable == true
        let percent = (available && !warming) ? cpu?.totalUsage : nil
        let details: [String] = {
            guard let cpu, available else {
                return [cpu?.availability.displayText ?? "Collecting…"]
            }
            if warming { return ["Warming up…"] }
            return [
                "\(cpu.perCore.count) cores",
                "user \(Int(cpu.userPercent.rounded()))% · sys \(Int(cpu.systemPercent.rounded()))%"
            ]
        }()
        return ringMetricCard(
            icon: "cpu",
            title: "CPU",
            percent: percent,
            details: details,
            tint: Color(red: 0.36, green: 0.62, blue: 0.96),
            history: cpu?.history ?? []
        )
    }

    private var gpuCard: some View {
        let gpu = monitor.gpu
        let available = gpu?.availability.isAvailable == true
        let percent = available ? gpu?.totalUtilization : nil
        let details: [String] = {
            guard let gpu, available else {
                return [gpu?.availability.displayText ?? "Collecting…"]
            }
            let device = gpu.devices.first
            var lines: [String] = []
            if let device { lines.append(device.name) }
            if let utilization = device?.utilization {
                var parts = ["GPU \(Int(utilization.rounded()))%"]
                if let render = device?.renderUtilization { parts.append("render \(Int(render.rounded()))%") }
                if let tiler = device?.tilerUtilization { parts.append("tiler \(Int(tiler.rounded()))%") }
                lines.append(parts.joined(separator: " · "))
            } else if device != nil {
                lines.append("Utilization not exposed")
            }
            return lines.isEmpty ? ["No GPU devices"] : lines
        }()
        return ringMetricCard(
            icon: "square.stack.3d.up",
            title: "GPU",
            percent: percent,
            details: details,
            tint: Color(red: 0.64, green: 0.52, blue: 0.95),
            history: gpu?.history ?? []
        )
    }

    private var memoryCard: some View {
        let memory = monitor.memory
        let usage = memory?.usagePercent ?? 0
        let detail = "\(formatGB(memory?.usedBytes ?? 0)) / \(formatGB(memory?.totalBytes ?? 0)) · swap \(formatGB(memory?.swapUsedBytes ?? 0)) · \(memory?.pressure.level.rawValue ?? "collecting")"
        return metricCard(
            icon: "memorychip",
            title: "Memory",
            value: memory == nil ? "—" : "\(Int(usage.rounded()))",
            unit: memory == nil ? nil : "%",
            detail: detail,
            tint: Color(red: 0.36, green: 0.79, blue: 0.55),
            progress: memory == nil ? nil : usage,
            history: memory?.history ?? []
        )
    }

    private var diskCard: some View {
        let disk = monitor.disk
        let root = disk?.volumes.first(where: \.isRoot) ?? disk?.volumes.first
        let percentage = root?.usagePercent ?? 0
        let detail = "R \(rateText(disk?.readBytesPerSecond ?? 0)) · W \(rateText(disk?.writeBytesPerSecond ?? 0)) · \(formatGB(root?.freeBytes ?? 0)) free"
        return metricCard(
            icon: "internaldrive",
            title: "Disk",
            value: root == nil ? "—" : "\(Int(percentage.rounded()))",
            unit: root == nil ? nil : "%",
            detail: detail,
            tint: Color(red: 0.95, green: 0.67, blue: 0.33),
            progress: root == nil ? nil : percentage,
            history: disk?.historyRead ?? []
        )
    }

    private var networkCard: some View {
        let network = monitor.network
        let down = rateParts(network?.downloadBytesPerSecond ?? 0)
        let totalDown = formatGB(network?.totalDownloadedBytes ?? 0)
        let detail = "↑ \(rateText(network?.uploadBytesPerSecond ?? 0)) · total \(totalDown)"
        return metricCard(
            icon: "network",
            title: "Network",
            value: network == nil ? "—" : "↓ \(down.value)",
            unit: network == nil ? nil : down.unit,
            detail: detail,
            tint: Color(red: 0.33, green: 0.76, blue: 0.78),
            progress: nil,
            history: network?.historyDownload ?? []
        )
    }

    private var temperatureCard: some View {
        let thermal = monitor.thermal
        let readings = thermal?.sensors
            ?? TemperatureReading.Kind.allCases.map { TemperatureReading(kind: $0, celsius: nil) }

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(red: 0.95, green: 0.45, blue: 0.45).opacity(0.20))
                    Image(systemName: "thermometer.medium")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.95, green: 0.45, blue: 0.45))
                }
                .frame(width: 22, height: 22)
                Text("TEMPERATURES")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.9))
                    .tracking(0.6)
                Spacer(minLength: 0)
                if let thermal {
                    Text(thermal.level.displayName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 3) {
                ForEach(readings) { reading in
                    HStack(spacing: 5) {
                        Image(systemName: reading.kind.symbolName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(reading.kind.tint)
                            .frame(width: 14)
                        Text(reading.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text(MonitorFormat.temperature(reading.celsius))
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                    }
                }
            }

            if let fan = thermal?.fanRPM {
                Text("Fan \(fan) RPM")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func ringMetricCard(
        icon: String,
        title: String,
        percent: Double?,
        details: [String],
        tint: Color,
        history: [Double]
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tint.opacity(0.20))
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 22, height: 22)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.9))
                    .tracking(0.6)
                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(tint.opacity(0.16), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: min(max((percent ?? 0) / 100, 0), 1))
                        .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(percent.map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(tint)
                }
                .frame(width: 62, height: 62)

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(details.indices, id: \.self) { index in
                        Text(details[index])
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }

            if history.count > 2 {
                Sparkline(values: history, tint: tint)
                    .frame(height: 14)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 122, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: Core strip & compact row

    private var coreStrip: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("CPU CORES")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                Text("\(monitor.cpu?.perCore.count ?? 0)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 3) {
                if (monitor.cpu?.perCore.count ?? 0) == 0 {
                    Text("—").font(.system(size: 12)).foregroundStyle(.secondary)
                } else {
                    ForEach(monitor.cpu?.perCore.indices ?? 0..<0, id: \.self) { index in
                        let usage = monitor.cpu?.perCore[index] ?? 0
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(coreColor(usage))
                            .frame(maxWidth: .infinity)
                            .frame(height: 20)
                            .help(String(format: "Core %d: %.0f%%", index + 1, usage))
                    }
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
    }

    private var compactRow: some View {
        HStack(spacing: 8) {
            compactChip(icon: "waveform.path.ecg", title: "LOAD",
                        value: monitor.cpu?.loadAverage.map {
                            String(format: "%.2f / %.2f / %.2f", $0.oneMinute, $0.fiveMinutes, $0.fifteenMinutes)
                        } ?? "—")
            compactChip(icon: "list.bullet", title: "PROCS", value: "\(processCount)")
            compactChip(icon: batterySymbol, title: "BATTERY",
                        value: batteryPercentage.map { "\($0)%" } ?? "—")
            compactChip(icon: "clock", title: "UPTIME", value: uptimeText)
        }
    }

    private func compactChip(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Text(value)
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.06)))
    }

    // MARK: Card chrome

    private func metricCard(icon: String,
                            title: String,
                            value: String,
                            unit: String?,
                            detail: String,
                            tint: Color,
                            progress: Double?,
                            history: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(tint.opacity(0.20))
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .frame(width: 22, height: 22)
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.9))
                    .tracking(0.6)
                Spacer(minLength: 0)
            }

            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 25, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if let unit {
                    Text(unit)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if history.count > 2 {
                Sparkline(values: history, tint: tint)
                    .frame(height: 16)
            } else if let progress {
                MeterBar(fraction: min(max(progress / 100, 0), 1), tint: tint)
                    .frame(height: 4)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.08)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    // MARK: Formatting & extras

    private var batterySymbol: String {
        guard let batteryPercentage else { return "battery.0percent" }
        if batteryCharging { return "battery.100percent.bolt" }
        switch batteryPercentage {
        case 88...: return "battery.100percent"
        case 63...: return "battery.75percent"
        case 38...: return "battery.50percent"
        case 13...: return "battery.25percent"
        default: return "battery.0percent"
        }
    }

    private var uptimeText: String {
        let seconds = Int(monitor.cpu?.uptime ?? 0)
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func rateParts(_ bytesPerSecond: Double) -> (value: String, unit: String) {
        let text = MonitorFormat.rate(bytesPerSecond)
        let components = text.split(separator: " ", maxSplits: 1)
        guard components.count == 2 else { return (text, "") }
        return (String(components[0]), String(components[1]))
    }

    private func rateText(_ bytesPerSecond: Double) -> String {
        MonitorFormat.rate(bytesPerSecond)
    }

    private func formatGB(_ bytes: UInt64) -> String {
        bytes == 0 ? "0 GB" : MonitorFormat.bytes(bytes)
    }

    private func coreColor(_ usage: Double) -> Color {
        switch usage {
        case ..<25: return Color(red: 0.36, green: 0.70, blue: 0.55)
        case ..<60: return Color(red: 0.75, green: 0.72, blue: 0.35)
        default: return Color(red: 0.90, green: 0.45, blue: 0.40)
        }
    }

    private func refreshExtras() {
        let battery = MacBatteryManager.shared.currentStatus()
        batteryPercentage = battery.percentage
        batteryCharging = battery.isCharging
        processCount = Self.processCount()
    }

    /// `KERN_PROC_ALL` returns one `kinfo_proc` per process; the byte size
    /// divided by the record size is the process count, no `ps` spawn.
    private static func processCount() -> Int {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return 0 }
        return size / MemoryLayout<kinfo_proc>.stride
    }
}

// MARK: - Small drawing helpers

/// Normalised line chart of a metric's recent history.
private struct Sparkline: View {
    let values: [Double]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard values.count > 1 else { return }
                let maxValue = max(values.max() ?? 1, 1)
                let stepX = geo.size.width / CGFloat(values.count - 1)
                for (index, value) in values.enumerated() {
                    let x = CGFloat(index) * stepX
                    let y = geo.size.height
                        - CGFloat(min(max(value / maxValue, 0), 1)) * geo.size.height
                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(tint.opacity(0.9),
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct MeterBar: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, geo.size.width * CGFloat(fraction)))
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func scrollEdgeClear() -> some View {
        if #available(macOS 26.0, *) {
            self.scrollEdgeEffectHidden(true, for: .all)
        } else {
            self
        }
    }
}

/// `onScrollGeometryChange` is macOS 15+, while IslandBoard still deploys to 14.
/// On 14 the monitor keeps the old behaviour; on 15+ the close gesture is
/// suppressed until the content actually reaches its bottom edge.
private struct MonitorScrollBottomGate: ViewModifier {
    let onChange: (Bool) -> Void

    func body(content: Content) -> some View {
        if #available(macOS 15.0, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.visibleRect.maxY >= geometry.contentSize.height - 4
            } action: { _, atBottom in
                onChange(atBottom)
            }
        } else {
            content
        }
    }
}
