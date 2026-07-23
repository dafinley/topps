import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject private var store: ToppsStore
    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 250)
        } content: {
            VStack(spacing: 0) {
                SystemSummaryView(system: store.system)
                Divider()
                content
            }
            .navigationTitle(store.selectedSection?.rawValue ?? "Topps")
        } detail: {
            ProcessInspectorView()
                .navigationSplitViewColumnWidth(min: 300, ideal: 340, max: 440)
        }
        .toolbar { ToolbarContentView() }
        .searchable(text: $store.searchText, placement: .toolbar, prompt: "Name, command, PID, user…")
        .task { store.start() }
        .onChange(of: store.selectedIdentity) { _, identity in
            store.select(identity.flatMap { id in store.processes.first { $0.identity == id } })
        }
        .alert("Topps", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    @ViewBuilder private var content: some View {
        switch store.selectedSection ?? .processes {
        case .processes: ProcessTableView()
        case .applications: ProcessGroupView()
        case .tree: ProcessTreeView()
        case .memory: MemoryInvestigationView()
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
        .help("Individual process memory does not sum exactly to system memory because macOS also accounts for kernel and wired memory, shared memory and frameworks, compressed memory, file cache, and other accounting differences.")
    }
}

struct ToolbarContentView: ToolbarContent {
    @EnvironmentObject private var store: ToppsStore
    var body: some ToolbarContent {
        ToolbarItemGroup {
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

struct ProcessTableView: View {
    @EnvironmentObject private var store: ToppsStore
    var body: some View {
        Table(store.filteredProcesses, selection: $store.selectedIdentity) {
            TableColumn("Process") { process in
                HStack(spacing: 7) {
                    ProcessIcon(process: process, size: 22)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(process.name).lineLimit(1)
                        AttentionIndicators(process: process)
                    }
                }.contextMenu { processMenu(process) }
            }.width(min: 170, ideal: 245)
            TableColumn("PID") { Text(process: $0.pid).monospacedDigit().foregroundStyle(.secondary) }.width(55)
            TableColumn("CPU") { process in Text(process.cpuPercent, format: .number.precision(.fractionLength(1))).monospacedDigit().foregroundStyle(process.cpuPercent > 80 ? .orange : .primary) }.width(55)
            TableColumn("Footprint") { process in
                VStack(alignment: .trailing, spacing: 1) {
                    HStack(spacing: 4) {
                        if process.hasLedgerHeavyFootprint {
                            Image(systemName: "info.circle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        Text(ByteFormat.string(process.memory)).monospacedDigit()
                    }
                    if let resident = process.residentMemory {
                        Text("Resident \(ByteFormat.string(resident))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .help(footprintHelp(process))
            }.width(min: 105, ideal: 125)
            TableColumn("Δ Footprint") { process in Text(ByteFormat.signed(process.memoryChange)).monospacedDigit().foregroundStyle(process.memoryChange > 0 ? .orange : process.memoryChange < 0 ? .green : .secondary) }.width(min: 78, ideal: 92)
            TableColumn("Threads") { Text(($0.threadCount.map(String.init) ?? "—")).monospacedDigit().foregroundStyle(.secondary) }.width(60)
            TableColumn("Parent") { process in Text(parentName(for: process)).lineLimit(1).foregroundStyle(process.isDetached ? .orange : .secondary) }.width(min: 82, ideal: 115)
            TableColumn("Runtime") { Text(DurationFormat.string($0.runtime)).monospacedDigit().foregroundStyle(.secondary) }.width(70)
            TableColumn("State") { Text($0.state.rawValue).foregroundStyle(.secondary) }.width(65)
        }
        .overlay { if store.filteredProcesses.isEmpty { ContentUnavailableView("No matching processes", systemImage: "line.3.horizontal.decrease.circle", description: Text("Try clearing search or filters.")) } }
    }

    @ViewBuilder private func processMenu(_ process: ProcessSnapshot) -> some View {
        Button("Copy PID") { store.copy(String(process.pid)) }
        Button("Copy Command") { store.copy(process.displayCommand) }
        Divider()
        Button(store.pinned.contains(process.identity) ? "Unpin" : "Pin Process") { store.togglePin(process) }
        Button(store.watched.contains(process.identity) ? "Stop Watching Growth" : "Watch for Growth") { store.toggleWatch(process) }
    }

    private func parentName(for process: ProcessSnapshot) -> String {
        store.processes.first { $0.pid == process.ppid }?.name ?? (process.ppid == 1 ? "launchd" : String(process.ppid))
    }

    private func footprintHelp(_ process: ProcessSnapshot) -> String {
        let footprint = process.physicalFootprint.map { ByteFormat.string($0) } ?? "Unavailable"
        let resident = process.residentMemory.map { ByteFormat.string($0) } ?? "Unavailable"
        return "Physical footprint \(footprint) is macOS’s ledger charge to this process. Resident pages \(resident) are a different measurement. Footprint can include compressed, swapped, shared, graphics, and device-backed allocations, so it can exceed installed RAM and must not be compared directly with system PhysMem Used."
    }
}

private extension Text {
    init(process pid: Int32) { self.init(String(pid)) }
}

struct ProcessGroupView: View {
    @EnvironmentObject private var store: ToppsStore
    @State private var expanded: Set<String> = []
    var body: some View {
        List {
            ForEach(store.groups) { group in
                DisclosureGroup(isExpanded: Binding(get: { expanded.contains(group.id) }, set: { value in
                    if value { expanded.insert(group.id) } else { expanded.remove(group.id) }
                })) {
                    ForEach(members(for: group)) { process in
                        groupMemberRow(process)
                            .contentShape(Rectangle())
                            .onTapGesture { store.select(process) }
                            .padding(.vertical, 2)
                    }
                } label: {
                    HStack(spacing: 10) {
                        ProcessIcon(process: group.highestConsumer, size: 28)
                        VStack(alignment: .leading) { Text(group.name).fontWeight(.medium); Text("\(group.memberIDs.count) processes · \(group.totalThreads) threads").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        VStack(alignment: .trailing) { Text(ByteFormat.string(group.totalMemory)).monospacedDigit(); Text(ByteFormat.signed(group.memoryGrowth)).font(.caption).foregroundStyle(group.memoryGrowth > 0 ? .orange : .secondary) }
                        Text(String(format: "%.1f%%", group.totalCPU)).monospacedDigit().frame(width: 65, alignment: .trailing)
                    }.padding(.vertical, 4)
                }
            }
        }.overlay { if store.groups.isEmpty { ProgressView("Sampling processes…") } }
    }

    private func groupMemberRow(_ process: ProcessSnapshot) -> some View {
        HStack {
            Color.clear.frame(width: 18)
            ProcessIcon(process: process, size: 20)
            Text(process.name).frame(maxWidth: .infinity, alignment: .leading)
            Text(process.cpuPercent, format: .number.precision(.fractionLength(1))).monospacedDigit().frame(width: 64, alignment: .trailing)
            Text(ByteFormat.string(process.memory)).monospacedDigit().frame(width: 90, alignment: .trailing)
        }
    }

    private func members(for group: ProcessGroup) -> [ProcessSnapshot] {
        let identities = Set(group.memberIDs)
        let values = store.processes.filter { identities.contains($0.identity) }
        return values.sorted { $0.memory > $1.memory }
    }
}

private struct ProcessTreeNode: Identifiable {
    let process: ProcessSnapshot
    let children: [ProcessTreeNode]?
    var id: ProcessIdentity { process.identity }
}

struct ProcessTreeView: View {
    @EnvironmentObject private var store: ToppsStore
    var body: some View {
        List(selection: $store.selectedIdentity) {
            OutlineGroup(roots, children: \.children) { node in
                HStack { ProcessIcon(process: node.process, size: 18); Text(node.process.name); Text(String(node.process.pid)).font(.caption.monospacedDigit()).foregroundStyle(.secondary); Spacer(); Text(ByteFormat.string(node.process.memory)).monospacedDigit(); Text(String(format: "%.1f%%", node.process.cpuPercent)).monospacedDigit().frame(width: 58, alignment: .trailing) }.tag(node.process.identity)
            }
        }
    }

    private var roots: [ProcessTreeNode] {
        let children = Dictionary(grouping: store.filteredProcesses, by: \.ppid)
        let allPIDs = Set(store.filteredProcesses.map(\.pid))
        return store.filteredProcesses.filter { !allPIDs.contains($0.ppid) || $0.ppid == $0.pid }.map { build($0, children: children, seen: []) }
    }

    private func build(_ process: ProcessSnapshot, children: [Int32: [ProcessSnapshot]], seen: Set<Int32>) -> ProcessTreeNode {
        guard !seen.contains(process.pid), seen.count < 64 else { return ProcessTreeNode(process: process, children: nil) }
        var next = seen; next.insert(process.pid)
        let values = children[process.pid]?.filter { !next.contains($0.pid) }.map { build($0, children: children, seen: next) }
        return ProcessTreeNode(process: process, children: values?.isEmpty == true ? nil : values)
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
