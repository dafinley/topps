import AppKit
import Foundation
import SwiftUI

@MainActor
final class ToppsStore: ObservableObject {
    @Published private(set) var processes: [ProcessSnapshot] = []
    @Published private(set) var groups: [ProcessGroup] = []
    @Published private(set) var system = SystemSnapshot()
    @Published var selectedIdentity: ProcessIdentity?
    @Published var selectedSection: MainSection? = .processes
    @Published var searchText = ""
    @Published var filter: ProcessFilter = .all
    @Published var sort: ProcessSort = .memory
    @Published var sortAscending = false
    @Published var refreshInterval: RefreshInterval = .oneSecond { didSet { restartSampling() } }
    @Published var minimumMemory: UInt64 = 0
    @Published var minimumCPU: Double = 0
    @Published var isFrozen = false
    @Published var selectedHistory: [HistoryPoint] = []
    @Published var selectedWorkingDirectory: String?
    @Published var selectedNetworkEndpoints: [NetworkEndpoint] = []
    @Published var diagnosticResult: DiagnosticResult?
    @Published var isRunningDiagnostic = false
    @Published var pinned: Set<ProcessIdentity> = []
    @Published var watched: Set<ProcessIdentity> = []
    @Published var hiddenProcessIDs: Set<ProcessIdentity> = []
    @Published var errorMessage: String?

    let provider: any ProcessDataProvider
    let historyStore: ProcessHistoryStore
    private var samplingTask: Task<Void, Never>?
    private var pending: SamplingResult?
    private var hasAutoSelectedInitialProcess = false
    private let currentUID = getuid()

    init(provider: any ProcessDataProvider = DarwinProcessDataProvider(), historyStore: ProcessHistoryStore = ProcessHistoryStore()) {
        self.provider = provider
        self.historyStore = historyStore
        if let raw = RefreshInterval(rawValue: UserDefaults.standard.double(forKey: "refreshInterval")), raw != .paused { refreshInterval = raw }
    }

    deinit { samplingTask?.cancel() }

    var selectedProcess: ProcessSnapshot? {
        guard let selectedIdentity else { return nil }
        return processes.first { $0.identity == selectedIdentity }
    }

    var filteredProcesses: [ProcessSnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return processes.filter { process in
            guard !hiddenProcessIDs.contains(process.identity), process.memory >= minimumMemory, process.cpuPercent >= minimumCPU else { return false }
            switch filter {
            case .all: break
            case .myProcesses: guard process.userID == currentUID else { return false }
            case .applications: guard process.isGUIApplication else { return false }
            case .commandLine: guard !process.isGUIApplication else { return false }
            case .detached: guard process.isDetached else { return false }
            }
            guard !query.isEmpty else { return true }
            return process.name.lowercased().contains(query)
                || process.displayCommand.lowercased().contains(query)
                || process.executablePath?.lowercased().contains(query) == true
                || process.bundleIdentifier?.lowercased().contains(query) == true
                || process.user.lowercased().contains(query)
                || String(process.pid).contains(query)
        }.sorted(by: compare)
    }

    func start() {
        guard samplingTask == nil else { return }
        samplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if self.refreshInterval == .paused {
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                await self.refresh()
                let seconds = self.refreshInterval.rawValue
                try? await Task.sleep(for: .seconds(seconds))
            }
        }
    }

    func stop() { samplingTask?.cancel(); samplingTask = nil }

    func refresh() async {
        let result = await provider.sample()
        await historyStore.ingest(result)
        if isFrozen { pending = result; return }
        apply(result)
    }

    func setFrozen(_ frozen: Bool) {
        isFrozen = frozen
        if !frozen, let pending { self.pending = nil; apply(pending) }
    }

    func select(_ process: ProcessSnapshot?) {
        selectedIdentity = process?.identity
        selectedWorkingDirectory = nil
        selectedNetworkEndpoints = []
        Task { [weak self] in
            guard let self, let process else { return }
            async let history = historyStore.history(for: process.identity)
            async let cwd = provider.loadWorkingDirectory(for: process.pid)
            async let endpoints = provider.loadNetworkEndpoints(for: process.pid)
            selectedHistory = await history
            selectedWorkingDirectory = await cwd
            selectedNetworkEndpoints = await endpoints
        }
    }

    func reloadNetworkEndpoints() {
        guard let process = selectedProcess else { return }
        Task { [weak self] in
            self?.selectedNetworkEndpoints = await self?.provider.loadNetworkEndpoints(for: process.pid) ?? []
        }
    }

    func runDiagnostic(_ kind: DiagnosticKind) {
        guard let process = selectedProcess else { return }
        isRunningDiagnostic = true
        Task { [weak self] in
            let result = await DiagnosticRunner.run(kind, pid: process.pid)
            self?.diagnosticResult = result
            self?.isRunningDiagnostic = false
        }
    }

    func signal(_ signal: Int32, process: ProcessSnapshot) {
        do { try ProcessSignalService.send(signal, to: process) }
        catch { errorMessage = error.localizedDescription }
    }

    func togglePin(_ process: ProcessSnapshot) {
        if pinned.contains(process.identity) { pinned.remove(process.identity) } else { pinned.insert(process.identity) }
    }

    func toggleWatch(_ process: ProcessSnapshot) {
        if watched.contains(process.identity) { watched.remove(process.identity) } else { watched.insert(process.identity) }
    }

    func pauseMonitoring(_ process: ProcessSnapshot) { hiddenProcessIDs.insert(process.identity); if selectedIdentity == process.identity { selectedIdentity = nil } }

    func children(of process: ProcessSnapshot) -> [ProcessSnapshot] { processes.filter { $0.ppid == process.pid } }

    func ancestry(of process: ProcessSnapshot) -> [ProcessSnapshot] { ProcessGroupingService.ancestry(of: process, among: processes) }

    func copy(_ string: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(string, forType: .string) }

    func export(format: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == "csv" ? [.commaSeparatedText] : [.json]
        panel.nameFieldStringValue = "topps-snapshot-\(Int(Date().timeIntervalSince1970)).\(format)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = format == "csv" ? ExportService.csv(processes: filteredProcesses) : try ExportService.json(processes: filteredProcesses)
            try data.write(to: url, options: .atomic)
        } catch { errorMessage = error.localizedDescription }
    }

    private func apply(_ result: SamplingResult) {
        processes = result.processes
        system = result.system
        groups = ProcessGroupingService.groups(from: result.processes)
        if !hasAutoSelectedInitialProcess {
            hasAutoSelectedInitialProcess = true
            selectedIdentity = processes.max(by: { $0.memory < $1.memory })?.identity
        }
        if let identity = selectedIdentity, !processes.contains(where: { $0.identity == identity }) { selectedIdentity = nil }
        if let identity = selectedIdentity {
            Task { [weak self] in self?.selectedHistory = await self?.historyStore.history(for: identity) ?? [] }
        }
    }

    private func compare(_ lhs: ProcessSnapshot, _ rhs: ProcessSnapshot) -> Bool {
        let result: Bool
        switch sort {
        case .memory: result = lhs.memory < rhs.memory
        case .cpu: result = lhs.cpuPercent < rhs.cpuPercent
        case .growth: result = lhs.memoryChangePerMinute < rhs.memoryChangePerMinute
        case .name: result = lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        case .pid: result = lhs.pid < rhs.pid
        case .runtime: result = lhs.runtime < rhs.runtime
        }
        return sortAscending ? result : !result
    }

    private func restartSampling() {
        UserDefaults.standard.set(refreshInterval.rawValue, forKey: "refreshInterval")
        if samplingTask != nil { stop(); start() }
    }
}
