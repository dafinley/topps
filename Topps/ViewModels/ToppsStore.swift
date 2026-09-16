import AppKit
import Foundation
import SwiftUI

enum AppMemorySafety {
    static let maximumFootprint: UInt64 = 1_000_000_000

    static func footprint(currentPID: Int32, in processes: [ProcessSnapshot]) -> UInt64? {
        processes.first { $0.pid == currentPID }?.memory
    }

    static func shouldPause(currentPID: Int32, processes: [ProcessSnapshot]) -> Bool {
        guard let footprint = footprint(currentPID: currentPID, in: processes) else { return false }
        return footprint >= maximumFootprint
    }
}

private struct LiveSnapshotState {
    var processes: [ProcessSnapshot] = []
    var groups: [ProcessGroup] = []
    var system = SystemSnapshot()
    var selfFootprint: UInt64 = 0
}

@MainActor
final class ToppsStore: ObservableObject {
    @Published private var liveState = LiveSnapshotState()
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
    @Published var networkEndpoints: [ProcessNetworkEndpoint] = []
    @Published var portDisplayFilter: PortDisplayFilter = .open
    @Published var isScanningPorts = false
    @Published var lastPortScan: Date?
    @Published var llmFitAnalysis: LLMFitAnalysis?
    @Published var llmFitUseCase: LLMFitUseCase = .general
    @Published var isAnalyzingLLMFit = false
    @Published var llmFitError: String?
    @Published private(set) var isLLMFitInstalled: Bool
    @Published private(set) var memorySafetyTripped = false
    @Published var storageSnapshots: [StorageSnapshot] = []
    @Published var selectedStorageRootPath = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var selectedStorageFindingPath: String?
    @Published var storageViewMode: StorageViewMode = .largest
    @Published var isScanningStorage = false
    @Published var storageScanError: String?
    @Published var diagnosticResult: DiagnosticResult?
    @Published var isRunningDiagnostic = false
    @Published var pinned: Set<ProcessIdentity> = []
    @Published var watched: Set<ProcessIdentity> = []
    @Published var hiddenProcessIDs: Set<ProcessIdentity> = []
    @Published var errorMessage: String?

    var processes: [ProcessSnapshot] { liveState.processes }
    var groups: [ProcessGroup] { liveState.groups }
    var system: SystemSnapshot { liveState.system }
    var selfFootprint: UInt64 { liveState.selfFootprint }

    let provider: any ProcessDataProvider
    let historyStore: ProcessHistoryStore
    let storageHistoryStore: StorageHistoryStore
    private let llmFitProvider: any LLMFitProviding
    private var lastLLMFitAttempt: Date?
    private var samplingTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?
    private var historyRefreshTask: Task<Void, Never>?
    private var portScanTask: Task<Void, Never>?
    private var llmFitTask: Task<Void, Never>?
    private var storageScanTask: Task<Void, Never>?
    private var storageHistoryTask: Task<Void, Never>?
    private var pending: SamplingResult?
    private var hasAutoSelectedInitialProcess = false
    private var isRefreshing = false
    private let currentUID = getuid()

    init(
        provider: any ProcessDataProvider = DarwinProcessDataProvider(),
        historyStore: ProcessHistoryStore = ProcessHistoryStore(),
        storageHistoryStore: StorageHistoryStore = StorageHistoryStore(),
        llmFitProvider: any LLMFitProviding = LocalLLMFitProvider()
    ) {
        self.provider = provider
        self.historyStore = historyStore
        self.storageHistoryStore = storageHistoryStore
        self.llmFitProvider = llmFitProvider
        self.isLLMFitInstalled = llmFitProvider.isInstalled()
        if let raw = RefreshInterval(rawValue: UserDefaults.standard.double(forKey: "refreshInterval")), raw != .paused { refreshInterval = raw }
        if let path = UserDefaults.standard.string(forKey: "selectedStorageRootPath"), !path.isEmpty { selectedStorageRootPath = path }
    }

    deinit {
        samplingTask?.cancel()
        selectionTask?.cancel()
        historyRefreshTask?.cancel()
        portScanTask?.cancel()
        llmFitTask?.cancel()
        storageScanTask?.cancel()
        storageHistoryTask?.cancel()
    }

    var selectedProcess: ProcessSnapshot? {
        guard let selectedIdentity else { return nil }
        if let current = processes.first(where: { $0.identity == selectedIdentity }) { return current }
        // A fresh port owner may not exist in the paused monitoring snapshot yet.
        return selectedSection == .ports
            ? networkEndpoints.first(where: { $0.process.identity == selectedIdentity })?.process : nil
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

    var filteredNetworkEndpoints: [ProcessNetworkEndpoint] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return networkEndpoints.filter { record in
            switch portDisplayFilter {
            case .open: guard record.endpoint.isOpenPort else { return false }
            case .connected: guard record.endpoint.isConnected else { return false }
            case .all: break
            }
            guard !query.isEmpty else { return true }
            return record.process.name.lowercased().contains(query)
                || record.process.displayCommand.lowercased().contains(query)
                || record.process.user.lowercased().contains(query)
                || String(record.process.pid).contains(query)
                || String(record.endpoint.localPort).contains(query)
                || record.endpoint.localDisplay.lowercased().contains(query)
                || record.endpoint.remoteDisplay.lowercased().contains(query)
        }
    }

    var filteredLLMFitRecommendations: [LLMFitRecommendation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return llmFitAnalysis?.recommendations ?? [] }
        return llmFitAnalysis?.recommendations.filter { model in
            model.name.lowercased().contains(query)
                || model.provider.lowercased().contains(query)
                || model.category.lowercased().contains(query)
                || model.runtime.lowercased().contains(query)
                || model.bestQuant.lowercased().contains(query)
                || model.ollamaName?.lowercased().contains(query) == true
        } ?? []
    }

    var selectedStorageSnapshots: [StorageSnapshot] {
        storageSnapshots.filter { $0.rootPath == selectedStorageRootPath }.sorted { $0.capturedAt > $1.capturedAt }
    }

    var latestStorageSnapshot: StorageSnapshot? { selectedStorageSnapshots.first }
    var previousStorageSnapshot: StorageSnapshot? { selectedStorageSnapshots.dropFirst().first }

    var storageFindings: [StorageFinding] {
        guard let current = latestStorageSnapshot else { return [] }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return StorageAnalysis.findings(current: current, previous: previousStorageSnapshot).filter { finding in
            let matchesMode: Bool
            switch storageViewMode {
            case .growth: matchesMode = finding.growth.map { $0 > 0 } ?? false
            case .cleanup: matchesMode = finding.recommendation == .reviewDelete
            case .move: matchesMode = finding.recommendation == .externalStorage || finding.recommendation == .cloudArchive
            case .largest: matchesMode = true
            }
            guard matchesMode else { return false }
            guard !query.isEmpty else { return true }
            return finding.entry.name.lowercased().contains(query)
                || finding.entry.path.lowercased().contains(query)
                || finding.entry.category.label.lowercased().contains(query)
                || finding.recommendation.label.lowercased().contains(query)
        }.sorted { lhs, rhs in
            switch storageViewMode {
            case .growth: return (lhs.growth ?? Int64.min) > (rhs.growth ?? Int64.min)
            case .cleanup, .move, .largest: return lhs.entry.allocatedBytes > rhs.entry.allocatedBytes
            }
        }
    }

    var selectedStorageFinding: StorageFinding? {
        guard let selectedStorageFindingPath, let current = latestStorageSnapshot else { return nil }
        return StorageAnalysis.findings(current: current, previous: previousStorageSnapshot).first { $0.entry.path == selectedStorageFindingPath }
    }

    func start() {
        loadStorageHistory()
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
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let result = await provider.sample()
        guard !Task.isCancelled else { return }
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
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            guard let self, let process else { return }
            async let history = historyStore.history(for: process.identity)
            async let cwd = provider.loadWorkingDirectory(for: process.pid)
            async let endpoints = provider.loadNetworkEndpoints(for: process.pid)
            let loaded = await (history, cwd, endpoints)
            guard !Task.isCancelled, selectedIdentity == process.identity else { return }
            selectedHistory = loaded.0
            selectedWorkingDirectory = loaded.1
            selectedNetworkEndpoints = loaded.2
        }
    }

    func reloadNetworkEndpoints() {
        guard let process = selectedProcess else { return }
        Task { [weak self] in
            self?.selectedNetworkEndpoints = await self?.provider.loadNetworkEndpoints(for: process.pid) ?? []
        }
    }

    /// Called only on page entry. No timer or off-screen refresh is created.
    func refreshPageIfNeeded(_ section: MainSection, now: Date = Date()) {
        if section == .llmFit { refreshLLMFitAvailability() }
        guard !memorySafetyTripped else { return }
        switch section {
        case .ports:
            if PageRefreshPolicy.isStale(lastPortScan, maxAge: PageRefreshPolicy.portsMaxAge, now: now) {
                scanPorts()
            }
        case .llmFit:
            // The first analysis remains explicit. Re-entry can refresh an existing
            // result, with a retry cooldown so a failed command cannot thrash.
            guard let analysis = llmFitAnalysis, isLLMFitInstalled,
                  PageRefreshPolicy.isStale(analysis.analyzedAt, maxAge: PageRefreshPolicy.llmFitMaxAge, now: now),
                  PageRefreshPolicy.isStale(lastLLMFitAttempt, maxAge: PageRefreshPolicy.llmFitMaxAge, now: now) else { return }
            analyzeLLMFit(now: now)
        case .processes, .applications, .tree, .memory, .storage:
            break
        }
    }

    func scanPorts() {
        guard !isScanningPorts else { return }
        let provider = provider
        isScanningPorts = true
        portScanTask?.cancel()
        portScanTask = Task { [weak self] in
            let records = await NetworkPortScanner.scan(provider: provider)
            guard !Task.isCancelled, let self else { return }
            networkEndpoints = records
            lastPortScan = Date()
            isScanningPorts = false
        }
    }

    func analyzeLLMFit(now: Date = Date()) {
        guard !isAnalyzingLLMFit else { return }
        refreshLLMFitAvailability()
        guard isLLMFitInstalled else {
            llmFitError = LLMFitServiceError.executableNotFound.localizedDescription
            return
        }
        let useCase = llmFitUseCase
        let provider = llmFitProvider
        lastLLMFitAttempt = now
        llmFitError = nil
        isAnalyzingLLMFit = true
        llmFitTask?.cancel()
        llmFitTask = Task { [weak self] in
            do {
                let analysis = try await provider.analyze(useCase: useCase)
                guard !Task.isCancelled, let self else { return }
                llmFitAnalysis = analysis
                isAnalyzingLLMFit = false
            } catch {
                guard !Task.isCancelled, let self else { return }
                llmFitError = error.localizedDescription
                isAnalyzingLLMFit = false
            }
        }
    }

    func refreshLLMFitAvailability() {
        isLLMFitInstalled = llmFitProvider.isInstalled()
    }

    func loadStorageHistory() {
        guard storageHistoryTask == nil else { return }
        storageHistoryTask = Task { [weak self] in
            guard let self else { return }
            let snapshots = await storageHistoryStore.snapshots()
            guard !Task.isCancelled else { return }
            storageSnapshots = snapshots
            storageHistoryTask = nil
        }
    }

    func chooseStorageRoot() {
        let panel = NSOpenPanel()
        panel.title = "Choose a Folder to Track"
        panel.prompt = "Track Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = URL(fileURLWithPath: selectedStorageRootPath)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setStorageRoot(url)
        scanSelectedStorageRoot()
    }

    func setStorageRoot(_ url: URL) {
        selectedStorageRootPath = url.standardizedFileURL.path
        selectedStorageFindingPath = nil
        storageScanError = nil
        UserDefaults.standard.set(selectedStorageRootPath, forKey: "selectedStorageRootPath")
    }

    func scanSelectedStorageRoot() {
        guard !isScanningStorage else { return }
        let root = URL(fileURLWithPath: selectedStorageRootPath, isDirectory: true)
        isScanningStorage = true
        storageScanError = nil
        storageScanTask?.cancel()
        storageScanTask = Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await StorageScanner.scan(root: root)
                try Task.checkCancellation()
                storageSnapshots = try await storageHistoryStore.record(snapshot)
                selectedStorageFindingPath = nil
                isScanningStorage = false
                storageScanTask = nil
            } catch is CancellationError {
                isScanningStorage = false
                storageScanTask = nil
            } catch {
                storageScanError = error.localizedDescription
                isScanningStorage = false
                storageScanTask = nil
            }
        }
    }

    func cancelStorageScan() {
        storageScanTask?.cancel()
        // Leave the scan marked active until its worker has actually unwound.
        // Otherwise Cancel + Scan Again can overlap multiple filesystem walks.
    }

    func revealStorageItem(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
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
        let footprint = AppMemorySafety.footprint(currentPID: getpid(), in: result.processes) ?? 0
        liveState = LiveSnapshotState(
            processes: result.processes,
            groups: ProcessGroupingService.groups(from: result.processes),
            system: result.system,
            selfFootprint: footprint
        )
        if !hasAutoSelectedInitialProcess {
            hasAutoSelectedInitialProcess = true
            selectedIdentity = processes.max(by: { $0.memory < $1.memory })?.identity
        }
        if let identity = selectedIdentity, !processes.contains(where: { $0.identity == identity }) { selectedIdentity = nil }
        if let identity = selectedIdentity {
            historyRefreshTask?.cancel()
            historyRefreshTask = Task { [weak self] in
                guard let self else { return }
                let history = await historyStore.history(for: identity)
                guard !Task.isCancelled, selectedIdentity == identity else { return }
                selectedHistory = history
            }
        }
        enforceMemorySafety(for: result.processes)
    }

    private func enforceMemorySafety(for processes: [ProcessSnapshot]) {
        guard !memorySafetyTripped, AppMemorySafety.shouldPause(currentPID: getpid(), processes: processes) else { return }
        memorySafetyTripped = true
        refreshInterval = .paused
        if isScanningStorage {
            cancelStorageScan()
            storageScanError = "The storage scan was cancelled because Topps approached its memory safety limit."
            errorMessage = "Topps stopped the storage scan and paused live sampling because its physical footprint reached \(ByteFormat.string(selfFootprint)). No partial snapshot was saved."
        } else {
            errorMessage = "Topps paused itself because its physical footprint reached \(ByteFormat.string(selfFootprint)). This safety limit prevents a UI or sampling regression from exhausting application memory. Quit and relaunch Topps, then report the incident with the displayed footprint."
        }
    }

    private func compare(_ lhs: ProcessSnapshot, _ rhs: ProcessSnapshot) -> Bool {
        let result: Bool
        let equal: Bool
        switch sort {
        case .memory: result = lhs.memory < rhs.memory; equal = lhs.memory == rhs.memory
        case .cpu: result = lhs.cpuPercent < rhs.cpuPercent; equal = lhs.cpuPercent == rhs.cpuPercent
        case .growth: result = lhs.memoryChangePerMinute < rhs.memoryChangePerMinute; equal = lhs.memoryChangePerMinute == rhs.memoryChangePerMinute
        case .name:
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            result = order == .orderedAscending; equal = order == .orderedSame
        case .pid: result = lhs.pid < rhs.pid; equal = lhs.pid == rhs.pid
        case .runtime: result = lhs.startTime > rhs.startTime; equal = lhs.startTime == rhs.startTime
        }
        if equal { return lhs.pid < rhs.pid }
        return sortAscending ? result : !result
    }

    private func restartSampling() {
        UserDefaults.standard.set(refreshInterval.rawValue, forKey: "refreshInterval")
        if samplingTask != nil { stop(); start() }
    }
}
