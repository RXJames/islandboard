import SwiftUI

/// Lightweight Path-based chart with one or two series. Fixed capacity from
/// the service (120 points) keeps the body cheap and avoids Swift Charts'
/// per-update scaffolding.
struct MonitorHistoryChart: View {
    let primary: [Double]
    var secondary: [Double] = []
    let primaryTint: Color
    var secondaryTint: Color? = nil
    var primaryLabel: String? = nil
    var secondaryLabel: String? = nil
    var upperBound: Double? = nil
    var height: CGFloat = 160

    private var hasData: Bool {
        primary.count > 1 || secondary.count > 1
    }

    private var maxValue: Double {
        let values = primary + secondary
        return max(values.max() ?? 0, upperBound ?? 0, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if primaryLabel != nil || secondaryLabel != nil {
                HStack(spacing: 14) {
                    if let primaryLabel {
                        legend(primaryLabel, color: primaryTint)
                    }
                    if let secondaryLabel, let secondaryTint {
                        legend(secondaryLabel, color: secondaryTint)
                    }
                    Spacer()
                }
            }

            if hasData {
                GeometryReader { geometry in
                    let size = geometry.size
                    ZStack {
                        grid(size: size)
                        if primary.count > 1 {
                            areaPath(size: size, values: primary)
                                .fill(
                                    LinearGradient(
                                        colors: [primaryTint.opacity(0.28), primaryTint.opacity(0.02)],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                            linePath(size: size, values: primary)
                                .stroke(primaryTint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        }
                        if secondary.count > 1, let secondaryTint {
                            linePath(size: size, values: secondary)
                                .stroke(secondaryTint, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        }
                    }
                }
                .frame(height: height)
            } else {
                MonitorEmptyState(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "Collecting…",
                    message: "History appears after the second sample."
                )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("History chart")
    }

    private func legend(_ label: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func grid(size: CGSize) -> some View {
        Path { path in
            for fraction in [0.25, 0.5, 0.75] {
                let y = size.height * fraction
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(Color.primary.opacity(0.06), style: StrokeStyle(lineWidth: 1, dash: [3, 4]))
    }

    private func points(size: CGSize, values: [Double]) -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let step = size.width / CGFloat(values.count - 1)
        return values.enumerated().map { index, value in
            let normalized = min(max(value / maxValue, 0), 1)
            return CGPoint(
                x: CGFloat(index) * step,
                y: size.height - CGFloat(normalized) * size.height
            )
        }
    }

    private func linePath(size: CGSize, values: [Double]) -> Path {
        var path = Path()
        let points = points(size: size, values: values)
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    private func areaPath(size: CGSize, values: [Double]) -> Path {
        var path = linePath(size: size, values: values)
        guard let last = points(size: size, values: values).last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: size.height))
        path.addLine(to: CGPoint(x: 0, y: size.height))
        path.closeSubpath()
        return path
    }
}
