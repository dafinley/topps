import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var store: ToppsStore
    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 250)
        } content: {
            centerColumn
        } detail: {
            detailColumn
        }
        .toolbar { ToolbarContentView() }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: searchPrompt)
        .task { store.start() }
        .onChange(of: store.selectedIdentity) { _, _ in
            store.select(store.selectedProcess)
        }
        .alert("Topps", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private var centerColumn: some View {
        VStack(spacing: 0) {
            if (store.selectedSection ?? .processes).showsSystemSummary {
                SystemSummaryView(system: store.system)
                Divider()
            }
            content
        }
        .navigationTitle(store.selectedSection?.rawValue ?? "Topps")
    }

    @ViewBuilder private var detailColumn: some View {
        if store.selectedSection == .storage {
            StorageInspectorView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 440)
        } else {
            ProcessInspectorView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 440)
        }
    }

    @ViewBuilder private var content: some View {
        switch store.selectedSection ?? .processes {
        case .processes: ProcessTableView()
        case .applications: ProcessGroupView()
        case .tree: ProcessTreeView()
        case .memory: MemoryInvestigationView()
        case .storage: StorageGrowthView()
        case .ports: PortsView()
        case .llmFit: LLMFitView()
        }
    }

    private var searchPrompt: String {
        switch store.selectedSection ?? .processes {
        case .storage: "File, folder, category, path…"
        case .ports: "Process, PID, address, port…"
        case .llmFit: "Model, provider, runtime, quantization…"
        default: "Name, command, PID, user…"
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject private var store: ToppsStore
    var body: some View {
        List(selection: $store.selectedSection) {
            Section("Explore") {
                ForEach(MainSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.icon).tag(section)
                }
            }
            if (store.selectedSection ?? .processes).showsProcessScope {
                Section("Scope") {
                    Picker("Processes", selection: $store.filter) {
                        ForEach(ProcessFilter.allCases) { filter in Text(filter.rawValue).tag(filter) }
                    }.labelsHidden()
                    LabeledContent("Footprint") {
                        Menu(store.minimumMemory == 0 ? "Any" : ByteFormat.string(store.minimumMemory)) {
                            Button("Any") { store.minimumMemory = 0 }
                            Button("Over 500 MB") { store.minimumMemory = 500_000_000 }
                            Button("Over 1 GB") { store.minimumMemory = 1_000_000_000 }
                            Button("Over 2 GB") { store.minimumMemory = 2_000_000_000 }
                            Button("Over 4 GB") { store.minimumMemory = 4_000_000_000 }
                        }.menuStyle(.borderlessButton)
                    }
                    LabeledContent("CPU") {
                        Menu(store.minimumCPU == 0 ? "Any" : "> \(Int(store.minimumCPU))%") {
                            ForEach([0, 10, 25, 50, 80], id: \.self) { value in Button(value == 0 ? "Any" : "Over \(value)%") { store.minimumCPU = Double(value) } }
                        }.menuStyle(.borderlessButton)
                    }
                }
            }
            if !store.pinned.isEmpty {
                Section("Pinned") {
                    ForEach(store.processes.filter { store.pinned.contains($0.identity) }) { process in
                        Button { store.select(process) } label: {
                            HStack { ProcessIcon(process: process, size: 18); Text(process.name).lineLimit(1); Spacer(); Text(ByteFormat.string(process.memory)).foregroundStyle(.secondary) }
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Circle().fill(store.refreshInterval == .paused ? Color.secondary : Color.green).frame(width: 7, height: 7)
                Text(store.refreshInterval == .paused ? "Paused" : "Live · \(store.refreshInterval.label)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                SelfMemoryLabel()
                Text("\(store.processes.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }.padding(10).background(.bar)
        }
    }
}

struct SystemSummaryView: View {
    let system: SystemSnapshot
    var body: some View {
        let reclaimable = system.availableMemory > system.unusedMemory ? system.availableMemory - system.unusedMemory : 0
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                MetricCard(title: "PhysMem Used", value: ByteFormat.string(system.usedMemory), detail: "of \(ByteFormat.string(system.totalMemory)) · top-style", color: .purple)
                MetricCard(title: "Available to Reuse", value: ByteFormat.string(system.availableMemory), detail: "\(ByteFormat.string(system.unusedMemory)) unused + \(ByteFormat.string(reclaimable)) inactive", color: .green)
                MetricCard(title: "CPU", value: String(format: "%.0f%%", system.totalCPU), detail: String(format: "User %.0f · System %.0f", system.userCPU, system.systemCPU), color: .blue)
                MetricCard(title: "Processes", value: system.processCount.formatted(), detail: "\(system.runningProcessCount) running · \(system.threadCount.formatted()) threads", color: .orange)
            }
            HStack(spacing: 10) {
                MemoryBar(system: system)
                PressureBadge(pressure: system.pressure)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

struct ToolbarContentView: ToolbarContent {
    @EnvironmentObject private var store: ToppsStore
    var body: some ToolbarContent {
        ToolbarItemGroup {
            if store.selectedSection == .storage {
                Button { store.chooseStorageRoot() } label: { Label("Choose Folder", systemImage: "folder.badge.plus") }
                    .disabled(store.isScanningStorage)
                if store.isScanningStorage {
                    Button { store.cancelStorageScan() } label: { Label("Cancel Scan", systemImage: "xmark") }
                } else {
                    Button { store.scanSelectedStorageRoot() } label: { Label("Scan Storage", systemImage: "internaldrive") }
                }
            } else if store.selectedSection == .ports {
                Button { store.scanPorts() } label: { Label("Scan Ports", systemImage: "network") }
                    .disabled(store.isScanningPorts)
            } else if store.selectedSection == .llmFit {
                Button { store.analyzeLLMFit() } label: { Label("Analyze LLM Fit", systemImage: "sparkles") }
                    .disabled(store.isAnalyzingLLMFit || !store.isLLMFitInstalled)
            } else {
                Picker("Sort", selection: $store.sort) { ForEach(ProcessSort.allCases) { Text($0.rawValue).tag($0) } }.frame(width: 105)
                Button { store.sortAscending.toggle() } label: { Image(systemName: store.sortAscending ? "arrow.up" : "arrow.down") }.help("Reverse sort order")
                Menu {
                    ForEach(RefreshInterval.allCases) { interval in Button { store.refreshInterval = interval } label: { if interval == store.refreshInterval { Label(interval.label, systemImage: "checkmark") } else { Text(interval.label) } } }
                } label: { Label(store.refreshInterval.label, systemImage: store.refreshInterval == .paused ? "pause.fill" : "arrow.clockwise") }
                Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }.disabled(store.refreshInterval != .paused && store.isFrozen).help("Refresh now")
                Menu {
                    Button("Export CSV…") { store.export(format: "csv") }
                    Button("Export JSON…") { store.export(format: "json") }
                    Divider()
                    Button("Copy Visible Rows") { store.copy(ExportService.tsv(processes: store.filteredProcesses)) }
                } label: { Image(systemName: "square.and.arrow.up") }
            }
        }
    }
}

struct ProcessGroupView: View {
    @EnvironmentObject private var store: ToppsStore
    var body: some View {
        ReusableProcessOutline(snapshot: .applications(groups: store.groups, processes: store.processes),
                               selection: $store.selectedIdentity)
    }
}

struct ProcessTreeView: View {
    @EnvironmentObject private var store: ToppsStore
    var body: some View {
        ReusableProcessOutline(snapshot: .tree(store.filteredProcesses), selection: $store.selectedIdentity)
    }
}

struct MemoryInvestigationView: View {
    @EnvironmentObject private var store: ToppsStore
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                investigationCard("Largest Footprints", icon: "memorychip", processes: Array(store.processes.sorted { $0.memory > $1.memory }.prefix(8)))
                investigationCard("Fastest Growth", icon: "chart.line.uptrend.xyaxis", processes: Array(store.processes.filter { $0.memoryChangePerMinute > 0 }.sorted { $0.memoryChangePerMinute > $1.memoryChangePerMinute }.prefix(8)), growth: true)
                investigationCard("Detached & Significant", icon: "link.badge.plus", processes: Array(store.processes.filter { $0.isDetached && $0.memory > 500_000_000 }.sorted { $0.memory > $1.memory }.prefix(8)))
                VStack(alignment: .leading, spacing: 8) {
                    Label("Largest Applications", systemImage: "square.stack.3d.up").font(.headline)
                    ForEach(store.groups.prefix(8)) { group in
                        HStack { Text(group.name).lineLimit(1); Spacer(); Text(ByteFormat.string(group.totalMemory)).monospacedDigit(); Text("\(group.memberIDs.count)").foregroundStyle(.secondary).frame(width: 28) }
                        Divider()
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).inspectorSection()
            }.padding(12)
            Text("Growth is an observation, not a leak diagnosis. Sustained memory growth may be expected; use diagnostics and application-specific profiling to investigate further.")
                .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom)
        }
    }

    private func investigationCard(_ title: String, icon: String, processes: [ProcessSnapshot], growth: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.headline)
            if processes.isEmpty { Text("No processes match this category.").foregroundStyle(.secondary).padding(.vertical) }
            ForEach(processes) { process in
                Button { store.select(process) } label: {
                    HStack { ProcessIcon(process: process, size: 18); Text(process.name).lineLimit(1); Spacer(); Text(growth ? ByteFormat.signed(Int64(process.memoryChangePerMinute)) + "/min" : ByteFormat.string(process.memory)).monospacedDigit().foregroundStyle(growth ? .orange : .primary) }
                }.buttonStyle(.plain)
                Divider()
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).inspectorSection()
    }
}

struct MainWindowView_Previews: PreviewProvider {
    static var previews: some View {
        MainWindowView()
            .environmentObject(ToppsStore(provider: MockProcessDataProvider()))
            .frame(width: 1_440, height: 860)
            .previewDisplayName("Topps — realistic process sample")
    }
}
