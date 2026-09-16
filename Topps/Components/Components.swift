import AppKit
import SwiftUI

/// This small view measures independently, including while process data is paused.
/// Publishing it through ToppsStore would invalidate the entire paused interface.
struct SelfMemoryLabel: View {
    @State private var footprint: UInt64?
    var body: some View {
        Text(footprint.map { "Topps \(ByteFormat.string($0))" } ?? "Topps —")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            .help("Current Topps footprint, refreshed even when process sampling is paused.")
            .task {
                while !Task.isCancelled {
                    var info = CPSProcessInfo()
                    if cps_read_process(getpid(), &info) == 1 {
                        footprint = info.physical_footprint > 0 ? info.physical_footprint : info.resident_bytes
                    }
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let detail: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded, weight: .semibold))
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .leading) { Rectangle().fill(color).frame(width: 2).clipShape(.rect(cornerRadius: 1)) }
    }
}

struct MemoryBar: View {
    let system: SystemSnapshot
    var showsLegend = true
    @State private var showsDetails = false

    private let wiredColor = Color.purple.opacity(0.95)
    private let compressedColor = Color.indigo.opacity(0.88)
    private let activeColor = Color.purple.opacity(0.66)
    private let inactiveColor = Color.purple.opacity(0.38)
    private let systemColor = Color.secondary.opacity(0.48)
    private let unusedColor = Color.secondary.opacity(0.18)

    var body: some View {
        let total = max(1, system.totalMemory)
        let composition = PhysicalMemoryComposition(system: system)
        VStack(alignment: .leading, spacing: 4) {
            if showsLegend {
                HStack(spacing: 5) {
                    Text("PHYSICAL MEMORY BREAKDOWN")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Button { showsDetails.toggle() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless)
                        .help("Explain these memory categories")
                        .popover(isPresented: $showsDetails, arrowEdge: .bottom) { details(composition) }
                    Spacer()
                    Text("Swap \(ByteFormat.string(system.swapUsed)) · disk, not shown in bar")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 14) {
                        legend("Wired", value: composition.wired, color: wiredColor)
                        legend("Compressed", value: composition.compressed, color: compressedColor)
                        legend("Active", value: composition.active, color: activeColor)
                        Spacer(minLength: 0)
                    }
                    HStack(spacing: 14) {
                        legend("Inactive/cache", value: composition.inactive, color: inactiveColor)
                        legend("System/other", value: composition.systemOther, color: systemColor)
                        legend("Unused", value: composition.unused, color: unusedColor)
                        Spacer(minLength: 0)
                    }
                }
            }
            GeometryReader { proxy in
                HStack(spacing: 1) {
                    segment(composition.wired, total: total, width: proxy.size.width, color: wiredColor)
                    segment(composition.compressed, total: total, width: proxy.size.width, color: compressedColor)
                    segment(composition.active, total: total, width: proxy.size.width, color: activeColor)
                    segment(composition.inactive, total: total, width: proxy.size.width, color: inactiveColor)
                    segment(composition.systemOther, total: total, width: proxy.size.width, color: systemColor)
                    segment(composition.unused, total: total, width: proxy.size.width, color: unusedColor)
                }
                .frame(width: proxy.size.width, height: 7)
                .clipShape(Capsule())
            }
            .frame(height: 7)
        }
        .frame(height: showsLegend ? 61 : 7)
        .accessibilityElement(children: showsLegend ? .contain : .ignore)
        .accessibilityLabel("Physical memory composition")
        .accessibilityValue("Wired \(ByteFormat.string(composition.wired)), compressed \(ByteFormat.string(composition.compressed)), active \(ByteFormat.string(composition.active)), inactive \(ByteFormat.string(composition.inactive)), system and other \(ByteFormat.string(composition.systemOther)), unused \(ByteFormat.string(composition.unused))")
    }

    private func segment(_ value: UInt64, total: UInt64, width: CGFloat, color: Color) -> some View {
        color.frame(width: max(0, width * CGFloat(value) / CGFloat(total)))
    }

    private func legend(_ label: String, value: UInt64, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text("\(label) \(ByteFormat.string(value))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func details(_ composition: PhysicalMemoryComposition) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Physical Memory Breakdown").font(.headline)
                Text("System-wide physical page states—not a sum of process footprints.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 9) {
                detailRow("Wired", value: composition.wired, color: wiredColor, explanation: "Kernel and driver memory; cannot be compressed or paged out.")
                detailRow("Compressed", value: composition.compressed, color: compressedColor, explanation: "Compressed pages held in RAM to avoid slower swap access.")
                detailRow("Active", value: composition.active, color: activeColor, explanation: "Recently used application, system, and file-backed pages.")
                detailRow("Inactive / cache", value: composition.inactive, color: inactiveColor, explanation: "Not recently used. Still ‘used’ in top, but reclaimable when needed.")
                detailRow("System / other", value: composition.systemOther, color: systemColor, explanation: "Residual kernel accounting not assigned to the Mach page states above.")
                detailRow("Unused", value: composition.unused, color: unusedColor, explanation: "Free plus speculative pages; excluded from top’s used figure.")
            }
            Divider()
            KeyValueRow(key: "Available", value: "\(ByteFormat.string(system.availableMemory)) = unused + inactive")
            KeyValueRow(key: "Purgeable", value: "\(ByteFormat.string(system.purgeableMemory)) · subset of active/inactive")
            KeyValueRow(key: "Swap used", value: "\(ByteFormat.string(system.swapUsed)) · stored on disk, not in this bar")
            Text("Inactive memory explains why Available to Reuse overlaps PhysMem Used. macOS keeps caches warm until another process needs the space.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 430)
    }

    private func detailRow(_ label: String, value: UInt64, color: Color, explanation: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8).padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                HStack { Text(label).font(.caption.weight(.semibold)); Spacer(); Text(ByteFormat.string(value)).font(.caption.monospacedDigit()) }
                Text(explanation).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

struct PressureBadge: View {
    let pressure: MemoryPressure
    var color: Color { switch pressure { case .normal: .green; case .warning: .orange; case .critical: .red } }
    var body: some View {
        Label(pressure.rawValue, systemImage: pressure == .normal ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .font(.caption.weight(.medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(color.opacity(0.1), in: Capsule())
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color
    var body: some View {
        Canvas { context, size in
            guard values.count > 1 else { return }
            let minimum = min(values.min() ?? 0, 0)
            let maximum = max(values.max() ?? 1, minimum + 1)
            var path = Path()
            for (index, value) in values.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(values.count - 1)
                let y = size.height - size.height * CGFloat((value - minimum) / (maximum - minimum))
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
        }
        .background(color.opacity(0.05), in: RoundedRectangle(cornerRadius: 4))
        .accessibilityLabel("History chart")
    }
}

struct ProcessIcon: View {
    let process: ProcessSnapshot
    var size: CGFloat = 24
    var body: some View {
        Group {
            if let image = icon { Image(nsImage: image).resizable() }
            else { Image(systemName: process.isGUIApplication ? "app.fill" : "terminal.fill").resizable().scaledToFit().padding(4).foregroundStyle(.secondary) }
        }
        .frame(width: size, height: size)
    }

    private var icon: NSImage? {
        ProcessIconCache.shared.icon(for: process)
    }
}

struct AttentionIndicators: View {
    let process: ProcessSnapshot
    var body: some View {
        HStack(spacing: 3) {
            if process.memory > 2_000_000_000 { indicator("memorychip.fill", .purple, "More than 2 GB") }
            if process.cpuPercent > 80 { indicator("gauge.with.dots.needle.67percent", .orange, "More than 80% CPU") }
            if process.memoryChangePerMinute > 100_000_000 { indicator("chart.line.uptrend.xyaxis", .red, "Growing faster than 100 MB/min") }
            if process.isDetached { indicator("link.badge.plus", .yellow, "Parent is launchd (PPID 1)") }
            if (process.threadCount ?? 0) > 64 { indicator("square.stack.3d.up.fill", .blue, "More than 64 threads") }
            if (process.fileDescriptorCount ?? 0) > 200 { indicator("doc.on.doc.fill", .mint, "More than 200 file descriptors") }
        }
    }
    private func indicator(_ icon: String, _ color: Color, _ help: String) -> some View {
        Image(systemName: icon)
            .font(.caption2)
            .foregroundStyle(color)
            .accessibilityLabel(help + ". This is an attention indicator, not a security finding.")
    }
}

struct KeyValueRow: View {
    let key: String
    let value: String
    var copyable = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            if copyable { Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            else { Text(value).frame(maxWidth: .infinity, alignment: .leading) }
        }.font(.caption)
    }
}

extension View {
    func inspectorSection() -> some View {
        self.padding(10).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
    }
}
