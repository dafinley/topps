import AppKit
import Darwin
import SwiftUI

struct ProcessInspectorView: View {
    @EnvironmentObject private var store: ToppsStore
    @State private var pendingSignal: Int32?
    var body: some View {
        Group {
            if let process = store.selectedProcess {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            header(process).id(process.identity)
                            attention(process)
                            network(process)
                            performance(process)
                            identity(process)
                            launch(process)
                            relations(process)
                            actions(process)
                            diagnostics
                        }.padding(12)
                    }
                    .onAppear { proxy.scrollTo(process.identity, anchor: .top) }
                    .onChange(of: process.identity) { _, identity in
                        proxy.scrollTo(identity, anchor: .top)
                    }
                }
                .navigationTitle("Inspector")
                .sheet(item: $store.diagnosticResult) { result in DiagnosticsView(result: result) }
                .confirmationDialog(pendingSignal == SIGKILL ? "Force quit \(process.name)?" : "Terminate \(process.name)?", isPresented: Binding(get: { pendingSignal != nil }, set: { if !$0 { pendingSignal = nil } })) {
                    if let signal = pendingSignal {
                        Button(signal == SIGKILL ? "Force Quit (SIGKILL)" : "Terminate (SIGTERM)", role: .destructive) { store.signal(signal, process: process); pendingSignal = nil }
                    }
                    Button("Cancel", role: .cancel) { pendingSignal = nil }
                } message: {
                    Text("PID \(process.pid) · Footprint \(ByteFormat.string(process.memory)) · \(store.children(of: process).count) child processes\n\n\(process.displayCommand)")
                }
            } else {
                ContentUnavailableView("Select a process", systemImage: "sidebar.right", description: Text("Choose a row to inspect command, ancestry, history, and diagnostics."))
            }
        }
    }

    private func header(_ process: ProcessSnapshot) -> some View {
        HStack(spacing: 10) {
            ProcessIcon(process: process, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(process.name).font(.title3.weight(.semibold)).lineLimit(1)
                HStack { Text("PID \(process.pid)").font(.caption.monospacedDigit()).foregroundStyle(.secondary); if process.isDetached { Label("Detached", systemImage: "link.badge.plus").font(.caption).foregroundStyle(.orange) } }
            }
            Spacer()
            Button { store.togglePin(process) } label: { Image(systemName: store.pinned.contains(process.identity) ? "pin.fill" : "pin") }.buttonStyle(.borderless).help("Pin process")
        }
    }

    @ViewBuilder private func attention(_ process: ProcessSnapshot) -> some View {
        if process.memory > 2_000_000_000 || process.cpuPercent > 80 || process.memoryChangePerMinute > 100_000_000 || process.isDetached || (process.threadCount ?? 0) > 64 || (process.fileDescriptorCount ?? 0) > 200 {
            HStack { AttentionIndicators(process: process); Text("Attention indicators").font(.caption).foregroundStyle(.secondary); Spacer() }.inspectorSection()
        }
        if process.hasLedgerHeavyFootprint {
            VStack(alignment: .leading, spacing: 7) {
                Label("Footprint is not resident RAM", systemImage: "info.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
                HStack {
                    Text("Ledger footprint \(ByteFormat.string(process.physicalFootprint ?? process.memory))")
                    Spacer()
                    Text("Resident pages \(ByteFormat.string(process.residentMemory ?? 0))")
                }
                .font(.caption.monospacedDigit())
                Text("macOS can charge compressed, swapped, shared, graphics, and device-backed allocations to a process. Those charges are not unique pages currently occupying DRAM, so footprint can exceed both installed memory and system PhysMem Used.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .inspectorSection()
        }
        if !process.isAccessible {
            Label("Detailed metrics unavailable for this protected process.", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary).inspectorSection()
        }
    }

    private func performance(_ process: ProcessSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("PERFORMANCE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                VStack(alignment: .leading) { Text(String(format: "%.1f%%", process.cpuPercent)).font(.title2.monospacedDigit().weight(.semibold)); Text("CPU · 10s avg \(String(format: "%.1f%%", process.cpuAverage10s))").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                VStack(alignment: .trailing) { Text(ByteFormat.string(process.memory)).font(.title2.monospacedDigit().weight(.semibold)); Text("Physical footprint · \(ByteFormat.signed(process.memoryChange)) last sample").font(.caption).foregroundStyle(process.memoryChange > 0 ? .orange : .secondary) }
            }
            historyBreakdown(process)
            if store.watched.contains(process.identity) { watchSummary(process) }
            Divider()
            KeyValueRow(key: "Footprint", value: process.physicalFootprint.map { ByteFormat.string($0) } ?? "Unavailable")
            KeyValueRow(key: "Resident pages", value: process.residentMemory.map { ByteFormat.string($0) } ?? "Unavailable")
            KeyValueRow(key: "FP / resident", value: process.footprintResidentRatio.map { String(format: "%.1f×", $0) } ?? "Unavailable")
            KeyValueRow(key: "Peak", value: process.peakPhysicalFootprint.map { ByteFormat.string($0) } ?? "Unavailable")
            KeyValueRow(key: "Growth/min", value: ByteFormat.signed(Int64(process.memoryChangePerMinute)))
            KeyValueRow(key: "CPU averages", value: String(format: "10s %.1f%% · 60s %.1f%%", process.cpuAverage10s, process.cpuAverage60s))
            KeyValueRow(key: "Threads / FDs", value: "\(process.threadCount.map(String.init) ?? "Unavailable") / \(process.fileDescriptorCount.map(String.init) ?? "Unavailable")")
            KeyValueRow(key: "Disk I/O", value: "Read \(process.bytesRead.map { ByteFormat.string($0) } ?? "Unavailable") · Written \(process.bytesWritten.map { ByteFormat.string($0) } ?? "Unavailable")")
            Divider()
            HStack {
                Button { store.runDiagnostic(.vmmap) } label: {
                    Label("Inspect Memory Regions…", systemImage: "square.3.layers.3d")
                }
                .disabled(store.isRunningDiagnostic)
                Spacer()
                Text("Explains footprint by region")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }.inspectorSection()
    }

    private func historyBreakdown(_ process: ProcessSnapshot) -> some View {
        let history = store.selectedHistory
        let cpuValues = history.map(\.cpu)
        let memoryValues = history.map(\.footprint).filter { $0 > 0 }
        let firstMemory = memoryValues.first ?? process.memory
        let lastMemory = memoryValues.last ?? process.memory
        let memoryDelta = lastMemory >= firstMemory
            ? Int64(clamping: lastMemory - firstMemory)
            : -Int64(clamping: firstMemory - lastMemory)
        let span = history.first.flatMap { first in history.last.map { $0.timestamp.timeIntervalSince(first.timestamp) } } ?? 0
        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("HISTORY · \(history.count) SAMPLES").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(span < 60 ? "\(Int(span))s" : "\(Int(span / 60))m span").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack {
                Text("CPU").font(.caption.weight(.medium))
                Spacer()
                Text("low \((cpuValues.min() ?? 0).formatted(.number.precision(.fractionLength(1))))% · avg \((cpuValues.isEmpty ? 0 : cpuValues.reduce(0, +) / Double(cpuValues.count)).formatted(.number.precision(.fractionLength(1))))% · high \((cpuValues.max() ?? 0).formatted(.number.precision(.fractionLength(1))))%")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            }
            Sparkline(values: cpuValues, color: .blue).frame(height: 44)
            HStack {
                Text("Physical footprint").font(.caption.weight(.medium))
                Spacer()
                Text("\(ByteFormat.string(firstMemory)) → \(ByteFormat.string(lastMemory)) · \(ByteFormat.signed(memoryDelta))")
                    .font(.caption2.monospacedDigit()).foregroundStyle(memoryDelta > 0 ? .orange : .secondary)
            }
            Sparkline(values: memoryValues.map(Double.init), color: .purple).frame(height: 52)
            HStack {
                Text(history.first?.timestamp.formatted(date: .omitted, time: .shortened) ?? "Waiting for samples")
                Spacer()
                Text("low \(ByteFormat.string(memoryValues.min() ?? process.memory)) · high \(ByteFormat.string(memoryValues.max() ?? process.memory))")
                Spacer()
                Text(history.last?.timestamp.formatted(date: .omitted, time: .shortened) ?? "Now")
            }.font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
        }.padding(8).background(.black.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func watchSummary(_ process: ProcessSnapshot) -> some View {
        let start = store.selectedHistory.first?.footprint ?? process.memory
        let growth = process.memory >= start ? Int64(clamping: process.memory - start) : -Int64(clamping: start - process.memory)
        let percent = start > 0 ? Double(growth) / Double(start) * 100 : 0
        return VStack(alignment: .leading, spacing: 3) {
            Label("Watching for sustained growth", systemImage: "eye.fill").font(.caption.weight(.semibold)).foregroundStyle(.orange)
            Text("Started at \(ByteFormat.string(start)) · \(ByteFormat.signed(growth)) (\(percent.formatted(.number.precision(.fractionLength(1))))%) · Peak \(ByteFormat.string(store.selectedHistory.map(\.footprint).max() ?? process.memory))").font(.caption2).foregroundStyle(.secondary)
        }.padding(7).background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func identity(_ process: ProcessSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("IDENTITY").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            KeyValueRow(key: "User", value: process.user)
            KeyValueRow(key: "State", value: process.state.rawValue)
            KeyValueRow(key: "Architecture", value: process.architecture + (process.isRosetta == true ? " · Rosetta" : ""))
            KeyValueRow(key: "Bundle ID", value: process.bundleIdentifier ?? "Unavailable", copyable: true)
            KeyValueRow(key: "Started", value: process.startTime.formatted(date: .abbreviated, time: .standard))
            KeyValueRow(key: "Runtime", value: DurationFormat.string(process.runtime))
            KeyValueRow(key: "Page faults", value: process.pageFaults?.formatted() ?? "Unavailable")
        }.inspectorSection()
    }

    private func launch(_ process: ProcessSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text("LAUNCH").font(.caption2.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Button("Copy command") { store.copy(process.displayCommand) }.buttonStyle(.borderless).font(.caption) }
            Text(process.displayCommand).font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            Text("Executable").font(.caption2).foregroundStyle(.secondary)
            Text(process.executablePath ?? "Unavailable").font(.caption.monospaced()).textSelection(.enabled)
            Text("Working directory").font(.caption2).foregroundStyle(.secondary)
            Text(store.selectedWorkingDirectory ?? "Unavailable").font(.caption.monospaced()).textSelection(.enabled)
        }.inspectorSection()
    }

    private func network(_ process: ProcessSnapshot) -> some View {
        let endpoints = store.selectedNetworkEndpoints
        let listeners = endpoints.filter(\.isListening).count
        let connected = endpoints.filter { $0.remotePort != 0 && !$0.isListening }.count
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("NETWORK PORTS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if !endpoints.isEmpty { Text("\(listeners) listening · \(connected) connected").font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                Button { store.reloadNetworkEndpoints() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).help("Refresh network endpoints")
            }
            if endpoints.isEmpty {
                Text(process.isAccessible ? "No TCP or UDP endpoints are currently visible." : "Network endpoints unavailable for this process.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(endpoints.prefix(32)) { endpoint in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(endpoint.protocolName).font(.caption2.monospaced().weight(.semibold)).foregroundStyle(endpoint.isListening ? .green : .blue).frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(endpoint.localDisplay).font(.caption.monospaced()).textSelection(.enabled)
                            HStack(spacing: 4) {
                                Text(endpoint.stateName)
                                if endpoint.remotePort != 0 { Text("→ \(endpoint.remoteDisplay)").textSelection(.enabled) }
                            }.font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("fd \(endpoint.fileDescriptor)").font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                    if endpoint.id != endpoints.prefix(32).last?.id { Divider() }
                }
                if endpoints.count > 32 { Text("\(endpoints.count - 32) additional endpoints not shown").font(.caption2).foregroundStyle(.secondary) }
            }
            Text("Read directly from this process’s socket file descriptors; no network request or continuous lsof scan is performed.")
                .font(.caption2).foregroundStyle(.secondary)
        }.inspectorSection()
    }

    private func relations(_ process: ProcessSnapshot) -> some View {
        let ancestry = store.ancestry(of: process)
        let children = store.children(of: process)
        return VStack(alignment: .leading, spacing: 6) {
            Text("RELATIONSHIPS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            KeyValueRow(key: "Parent", value: ancestry.first.map { "\($0.name) (\($0.pid))" } ?? (process.ppid == 1 ? "launchd (1)" : "Unavailable (\(process.ppid))"))
            KeyValueRow(key: "Process group", value: String(process.processGroupID))
            if !ancestry.isEmpty { Text(ancestry.reversed().map { "\($0.name) [\($0.pid)]" }.joined(separator: "  ›  ")).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
            if !children.isEmpty { Divider(); Text("Children (\(children.count))").font(.caption2).foregroundStyle(.secondary); ForEach(children.prefix(8)) { child in Button { store.select(child) } label: { HStack { Text(child.name); Spacer(); Text(String(child.pid)).monospacedDigit(); Text(ByteFormat.string(child.memory)).monospacedDigit() }.font(.caption) }.buttonStyle(.plain) } }
        }.inspectorSection()
    }

    private func actions(_ process: ProcessSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ACTIONS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack {
                Button("Copy PID") { store.copy(String(process.pid)) }
                Button(store.watched.contains(process.identity) ? "Stop Watching" : "Watch Growth") { store.toggleWatch(process) }
                Button("Reveal") { if let path = process.executablePath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } }.disabled(process.executablePath == nil)
            }
            HStack {
                Button("Terminate…") { pendingSignal = SIGTERM }.buttonStyle(.borderedProminent).tint(.red)
                Button("Force Quit…") { pendingSignal = SIGKILL }
                Button("Hide") { store.pauseMonitoring(process) }
            }.disabled(!ProcessSignalService.canSignal(process))
            Text("Topps never terminates a process automatically. Force Quit does not allow cleanup or saving.").font(.caption2).foregroundStyle(.secondary)
        }.inspectorSection()
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("ADVANCED DIAGNOSTICS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text("Runs the selected Apple command-line tool once, only when requested. No sudo or shell strings are used.").font(.caption2).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(DiagnosticKind.allCases) { kind in Button(kind.rawValue) { store.runDiagnostic(kind) }.font(.caption).disabled(store.isRunningDiagnostic) }
            }
            if store.isRunningDiagnostic { ProgressView("Collecting…").controlSize(.small) }
        }.inspectorSection()
    }
}

struct DiagnosticsView: View {
    let result: DiagnosticResult
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack { VStack(alignment: .leading) { Text(result.title).font(.headline); Text("PID \(result.pid) · \(result.timestamp.formatted())").font(.caption).foregroundStyle(.secondary) }; Spacer(); Button("Save…", action: save); Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result.output, forType: .string) }; Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding()
            Divider()
            ScrollView([.horizontal, .vertical]) { Text(filteredOutput).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .topLeading).padding() }
                .searchable(text: $search, prompt: "Find in output")
        }.frame(minWidth: 760, minHeight: 520)
    }
    private var filteredOutput: String { search.isEmpty ? result.output : result.output.split(separator: "\n", omittingEmptySubsequences: false).filter { $0.localizedCaseInsensitiveContains(search) }.joined(separator: "\n") }
    private func save() { let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]; panel.nameFieldStringValue = "\(result.title.replacingOccurrences(of: " ", with: "-"))-\(result.pid).txt"; if panel.runModal() == .OK, let url = panel.url { try? result.output.data(using: .utf8)?.write(to: url) } }
}
