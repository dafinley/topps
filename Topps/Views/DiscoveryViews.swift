import SwiftUI

private struct SnapshotRefreshStatus: View {
    let updatedAt: Date?
    let isRefreshing: Bool

    var body: some View {
        HStack(spacing: 5) {
            if isRefreshing {
                ProgressView().controlSize(.mini)
                Text("Refreshing…")
            } else if let updatedAt {
                Text("Updated \(updatedAt, style: .relative) ago")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

struct PortsView: View {
    @EnvironmentObject private var store: ToppsStore

    private var openCount: Int { store.networkEndpoints.count { $0.endpoint.isOpenPort } }
    private var connectedCount: Int { store.networkEndpoints.count { $0.endpoint.isConnected } }
    private var processCount: Int { Set(store.networkEndpoints.map(\.process.identity)).count }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.isScanningPorts && store.networkEndpoints.isEmpty {
                Spacer()
                ProgressView("Inspecting process sockets…")
                Text("This is an on-demand snapshot; it does not run during live sampling.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 5)
                Spacer()
            } else if store.filteredNetworkEndpoints.isEmpty {
                ContentUnavailableView {
                    Label(emptyTitle, systemImage: "network.slash")
                } description: {
                    Text(emptyDescription)
                } actions: {
                    Button("Scan Ports") { store.scanPorts() }
                        .disabled(store.isScanningPorts)
                }
            } else {
                List(store.filteredNetworkEndpoints) { record in
                    Button { store.select(record.process) } label: {
                        endpointRow(record)
                    }
                    .buttonStyle(.plain)
                    .listRowSeparator(.visible)
                }
                .listStyle(.inset)
            }
        }
        .task { store.refreshPageIfNeeded(.ports) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ports & Connections").font(.title2.weight(.semibold))
                    Text(store.memorySafetyTripped
                         ? "Automatic refresh is disabled after the memory-safety pause. Scan Now remains available."
                         : "Refreshes on entry when older than 10 seconds—even when monitoring is paused. Scan Now refreshes immediately.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                SnapshotRefreshStatus(updatedAt: store.lastPortScan, isRefreshing: store.isScanningPorts)
                Button { store.scanPorts() } label: {
                    Label(store.isScanningPorts ? "Scanning" : "Scan Now", systemImage: "arrow.clockwise")
                }
                .disabled(store.isScanningPorts)
            }
            HStack(spacing: 8) {
                MetricCard(title: "Open / Bound", value: openCount.formatted(), detail: "TCP listeners and bound UDP", color: .green)
                MetricCard(title: "Connected", value: connectedCount.formatted(), detail: "Sockets with a remote endpoint", color: .blue)
                MetricCard(title: "Owners", value: processCount.formatted(), detail: "Processes with visible sockets", color: .orange)
            }
            HStack {
                Picker("Show", selection: $store.portDisplayFilter) {
                    ForEach(PortDisplayFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)
                Spacer()
                Text("Some protected system processes cannot be inspected without additional privileges.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
    }

    private func endpointRow(_ record: ProcessNetworkEndpoint) -> some View {
        HStack(spacing: 10) {
            ProcessIcon(process: record.process, size: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.process.name).fontWeight(.medium).lineLimit(1)
                    Text("PID \(record.process.pid)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(record.process.user).font(.caption).foregroundStyle(.tertiary)
                }
                Text(record.process.displayCommand)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                HStack(spacing: 6) {
                    Text(record.endpoint.protocolName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(record.endpoint.protocolNumber == 6 ? .blue : .purple)
                    stateBadge(record.endpoint)
                    Text(record.endpoint.localPortDisplay)
                        .font(.body.monospacedDigit().weight(.semibold))
                }
                Text(connectionDescription(record.endpoint))
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func stateBadge(_ endpoint: NetworkEndpoint) -> some View {
        let title = endpoint.isBoundDatagram ? "Bound" : endpoint.stateName
        let color: Color = endpoint.isOpenPort ? .green : (endpoint.isConnected ? .blue : .secondary)
        return Text(title)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.1), in: Capsule())
    }

    private func connectionDescription(_ endpoint: NetworkEndpoint) -> String {
        endpoint.remotePort == 0 ? endpoint.localDisplay : "\(endpoint.localDisplay) → \(endpoint.remoteDisplay)"
    }

    private var emptyTitle: String {
        if store.lastPortScan == nil { return "No Port Snapshot" }
        if !store.searchText.isEmpty { return "No Matching Sockets" }
        return "No \(store.portDisplayFilter.rawValue) Sockets"
    }

    private var emptyDescription: String {
        if store.lastPortScan == nil { return "Discover current processes and inspect their listening ports and active connections. Works while monitoring is paused." }
        if !store.searchText.isEmpty { return "Try a process name, PID, username, address, or port number." }
        return "Nothing in the latest on-demand scan matches this filter."
    }
}

struct LLMFitView: View {
    @EnvironmentObject private var store: ToppsStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task { store.refreshPageIfNeeded(.llmFit) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Local LLM Fit").font(.title2.weight(.semibold))
                    Text(store.memorySafetyTripped
                         ? "Automatic refresh is disabled after the memory-safety pause. Manual analysis remains available."
                         : "Existing analyses refresh on entry after 5 minutes. The first analysis is manual.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Link("llmfit on GitHub", destination: URL(string: "https://github.com/AlexsJones/llmfit")!)
                    .font(.caption)
                Button { store.analyzeLLMFit() } label: {
                    Label(store.isAnalyzingLLMFit ? "Analyzing" : "Analyze This Mac", systemImage: "sparkles")
                }
                .disabled(store.isAnalyzingLLMFit || !store.isLLMFitInstalled)
            }
            HStack {
                Picker("Use case", selection: $store.llmFitUseCase) {
                    ForEach(LLMFitUseCase.allCases) { useCase in Text(useCase.label).tag(useCase) }
                }
                .frame(width: 220)
                Text("Returns up to 100 models rated Marginal or better. Re-run after changing the use case.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                SnapshotRefreshStatus(updatedAt: store.llmFitAnalysis?.analyzedAt, isRefreshing: store.isAnalyzingLLMFit)
            }
        }
        .padding(12)
    }

    @ViewBuilder private var content: some View {
        if let analysis = store.llmFitAnalysis {
            // A background refresh (or failure) must not replace cached results
            // with a full-screen spinner or discard the user's current filters.
            if let error = store.llmFitError {
                Label("Refresh failed; showing the last analysis. \(error)", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(12)
            } else if !store.isLLMFitInstalled {
                Label("llmfit is unavailable; showing the last analysis.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
            }
            analysisView(analysis)
        } else if !store.isLLMFitInstalled {
            ContentUnavailableView {
                Label("Install llmfit to Analyze Models", systemImage: "shippingbox")
            } description: {
                Text("Topps uses the llmfit command-line tool as an on-demand analysis engine. It is not bundled or kept running in the background.")
            } actions: {
                Button("Copy Install Command") { store.copy(LLMFitService.installCommand) }
                Button("Check Again") { store.refreshLLMFitAvailability() }
                Text(LLMFitService.installCommand)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
        } else if store.isAnalyzingLLMFit {
            Spacer()
            ProgressView("Detecting hardware and scoring local models…")
            Text("llmfit runs once and exits when the analysis is complete.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.top, 5)
            Spacer()
        } else if let error = store.llmFitError {
            ContentUnavailableView {
                Label("Analysis Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again") { store.analyzeLLMFit() }
            }
        } else {
            ContentUnavailableView {
                Label("Ready to Analyze This Mac", systemImage: "brain.head.profile")
            } description: {
                Text("Topps will ask llmfit to detect the CPU, memory, GPU backend, and rank models by fit, speed, quality, and context capacity.")
            } actions: {
                Button("Analyze This Mac") { store.analyzeLLMFit() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func analysisView(_ analysis: LLMFitAnalysis) -> some View {
        VStack(spacing: 0) {
            if let system = analysis.system {
                HStack(spacing: 8) {
                    MetricCard(title: "CPU", value: system.cpuName, detail: "\(system.cpuCores) cores", color: .blue)
                    MetricCard(title: "Memory", value: String(format: "%.1f GB", system.availableRAMGB), detail: String(format: "available of %.1f GB", system.totalRAMGB), color: .green)
                    MetricCard(title: "GPU", value: system.gpuName ?? "Not detected", detail: gpuDetail(system), color: .purple)
                    MetricCard(title: "Models", value: analysis.recommendations.count.formatted(), detail: "marginal fit or better", color: .orange)
                }
                .padding(12)
                Divider()
            }
            if store.filteredLLMFitRecommendations.isEmpty {
                ContentUnavailableView.search(text: store.searchText)
            } else {
                List(Array(store.filteredLLMFitRecommendations.enumerated()), id: \.element.id) { index, model in
                    modelRow(model, rank: index + 1)
                        .listRowSeparator(.visible)
                }
                .listStyle(.inset)
            }
            HStack {
                Text("Scores and throughput are estimates; benchmark before committing to a model.")
                Spacer()
                Text(analysis.executablePath).textSelection(.enabled)
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func modelRow(_ model: LLMFitRecommendation, rank: Int) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 18) {
                    detail("Quality", score(model.qualityScore))
                    detail("Speed", score(model.speedScore))
                    detail("Fit", score(model.fitScore))
                    detail("Context", score(model.contextScore))
                }
                if let ollama = model.ollamaName {
                    HStack { Text("Ollama").foregroundStyle(.secondary); Text("ollama pull \(ollama)").monospaced().textSelection(.enabled) }
                        .font(.caption)
                }
                ForEach(model.notes.prefix(3), id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 36)
            .padding(.vertical, 5)
        } label: {
            HStack(spacing: 10) {
                Text("#\(rank)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .frame(width: 28, alignment: .trailing)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.name).fontWeight(.medium).lineLimit(1)
                        if model.installed { Label("Installed", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green) }
                    }
                    Text("\(model.provider) · \(model.parameterCount) · \(model.category)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                fitBadge(model.fitLevel)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f", model.score)).font(.body.monospacedDigit().weight(.semibold))
                    Text("score").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(width: 48)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.1f tok/s", model.estimatedTPS)).monospacedDigit()
                    Text("\(String(format: "%.1f", model.memoryRequiredGB)) GB · \(model.bestQuant)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 125, alignment: .trailing)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.runMode).lineLimit(1)
                    Text("\(model.runtime) · \(context(model)) ctx")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(width: 125, alignment: .trailing)
            }
            .padding(.vertical, 4)
        }
    }

    private func fitBadge(_ fit: String) -> some View {
        let normalized = fit.lowercased()
        let color: Color = normalized.contains("perfect") ? .green : (normalized.contains("good") ? .blue : .orange)
        return Text(fit.replacingOccurrences(of: "_", with: " ").capitalized)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(color.opacity(0.1), in: Capsule())
    }

    private func detail(_ label: String, _ value: String) -> some View {
        LabeledContent(label, value: value).font(.caption).frame(width: 105)
    }

    private func score(_ value: Double?) -> String { value.map { String(format: "%.1f", $0) } ?? "—" }

    private func context(_ model: LLMFitRecommendation) -> String {
        let value = model.usableContext ?? model.contextLength
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.0fk", Double(value) / 1_000) }
        return value.formatted()
    }

    private func gpuDetail(_ system: LLMFitSystem) -> String {
        let memory = system.gpuVRAMGB.map { String(format: "%.1f GB", $0) } ?? "memory unavailable"
        return "\(system.backend) · \(memory)\(system.unifiedMemory ? " unified" : "")"
    }
}
