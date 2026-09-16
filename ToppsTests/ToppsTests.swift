import Darwin
import SwiftUI
import XCTest
@testable import Topps

final class ToppsTests: XCTestCase {
    @MainActor
    func testLiveTreeMemorySoak() async throws {
        try await runLiveOutlineSoak(applications: false)
    }

    @MainActor
    func testLiveApplicationsMemorySoak() async throws {
        try await runLiveOutlineSoak(applications: true)
    }

    @MainActor
    private func runLiveOutlineSoak(applications: Bool) async throws {
        let sources = MockProcessDataProvider.makeSample().processes
        let processes = (0..<320).map { index in
            replacing(sources[index % sources.count], pid: Int32(100_000 + index),
                      ppid: index % 8 == 0 ? 1 : Int32(100_000 + index / 8 * 8))
        }
        let store = ToppsStore(provider: SoakProcessProvider(processes: processes))
        let view = applications ? AnyView(ProcessGroupView()) : AnyView(ProcessTreeView())
        let host = NSHostingView(rootView: view.environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 650),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close(); store.stop() }
        var baseline: UInt64 = 0
        var peak: UInt64 = 0
        for iteration in 0..<4_000 {
            await store.refresh()
            host.layoutSubtreeIfNeeded()
            if iteration % 250 == 0, let outline = findOutline(in: host), let first = outline.item(atRow: 0) {
                if outline.isItemExpanded(first) { outline.collapseItem(first) }
                else { outline.expandItem(first) }
                if outline.numberOfRows > 1 { outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false) }
            }
            try await Task.sleep(for: .milliseconds(5))
            let footprint = currentPhysicalFootprint()
            if iteration == 999 { baseline = footprint }
            if iteration >= 1_000 { peak = max(peak, footprint) }
            if iteration % 500 == 499 { print("TOPPS_SOAK mode=\(applications ? "applications" : "tree") sample=\(iteration + 1) footprint=\(footprint)") }
        }
        let growth = peak > baseline ? peak - baseline : 0
        print("TOPPS_SOAK mode=\(applications ? "applications" : "tree") baseline=\(baseline) peak=\(peak) growth=\(growth) samples=4000 processes=320")
        XCTAssertGreaterThan(baseline, 0)
        XCTAssertLessThan(growth, 64_000_000, "Repeated live tree updates must settle after warm-up")
    }

    @MainActor
    private func findOutline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        for child in view.subviews { if let outline = findOutline(in: child) { return outline } }
        return nil
    }

    func testHistoryWrapsInOrderAndDropsStaleSamplesOnResume() async {
        let history = ProcessHistoryStore(capacity: 3)
        let sample = MockProcessDataProvider.makeSample()
        let identity = sample.processes[0].identity
        for second in 1...8 {
            await history.ingest(SamplingResult(timestamp: Date(timeIntervalSince1970: Double(second)), processes: sample.processes, system: sample.system))
        }
        let points = await history.history(for: identity)
        XCTAssertEqual(points.map { $0.timestamp.timeIntervalSince1970 }, [6, 7, 8])
        await history.ingest(SamplingResult(timestamp: Date(timeIntervalSince1970: 100), processes: sample.processes, system: sample.system))
        let resumed = await history.history(for: identity)
        XCTAssertEqual(resumed.map { $0.timestamp.timeIntervalSince1970 }, [100])
        await history.ingest(SamplingResult(timestamp: Date(timeIntervalSince1970: 200), processes: [], system: sample.system))
        let expired = await history.history(for: identity)
        XCTAssertTrue(expired.isEmpty)
    }

    func testNativeTreeRetainsEveryProcessWithCyclesAndMissingParents() {
        let source = MockProcessDataProvider.makeSample().processes[0]
        let values = [replacing(source, pid: 10, ppid: 11), replacing(source, pid: 11, ppid: 10),
                      replacing(source, pid: 12, ppid: 999), replacing(source, pid: 13, ppid: 13)]
        let tree = ProcessOutlineSnapshot.tree(values)
        XCTAssertEqual(tree.rows.count, 4)
        var visited: Set<String> = []
        func walk(_ id: String) {
            XCTAssertTrue(visited.insert(id).inserted, "No process can appear twice or create a cycle")
            for child in tree.rows[id]?.children ?? [] { if !visited.contains(child) { walk(child) } else { XCTFail("Cycle") } }
        }
        for root in tree.roots { walk(root) }
        XCTAssertEqual(visited, Set(values.map { $0.identity.id }))
    }

    func testSystemSamplerReleasesHostPortRights() {
        let host = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, host) }
        var before: mach_port_urefs_t = 0
        XCTAssertEqual(mach_port_get_refs(mach_task_self_, host, mach_port_right_t(MACH_PORT_RIGHT_SEND), &before), KERN_SUCCESS)
        for _ in 0..<1_000 { var info = CPSSystemInfo(); XCTAssertEqual(cps_read_system(&info), 1) }
        var after: mach_port_urefs_t = 0
        XCTAssertEqual(mach_port_get_refs(mach_task_self_, host, mach_port_right_t(MACH_PORT_RIGHT_SEND), &after), KERN_SUCCESS)
        XCTAssertEqual(after, before, "Sampling must not accumulate Mach send rights")
    }

    func testDarwinProviderEnumeratesTheCurrentProcess() async {
        let provider = DarwinProcessDataProvider()
        let sample = await provider.sample()
        XCTAssertTrue(
            sample.processes.contains { $0.pid == getpid() },
            "The native provider must return the complete PID list, including the test host"
        )
    }

    func testCPUPercentageUsesDeltaNotCumulativeTime() {
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertEqual(CPUDeltaCalculator.percentage(previousCPU: 20, currentCPU: 20.5, previousTime: start, currentTime: start.addingTimeInterval(1)), 50, accuracy: 0.001)
        XCTAssertEqual(CPUDeltaCalculator.percentage(previousCPU: 20, currentCPU: 19, previousTime: start, currentTime: start.addingTimeInterval(1)), 0)
        XCTAssertEqual(CPUDeltaCalculator.percentage(previousCPU: 20, currentCPU: 21, previousTime: start, currentTime: start), 0)
    }

    func testSystemUsedMemoryMatchesTopStyleUnusedAccounting() {
        let total: UInt64 = 16 * 1_024 * 1_024 * 1_024
        let unused: UInt64 = 129 * 1_024 * 1_024
        let inactive: UInt64 = 3_900 * 1_024 * 1_024
        XCTAssertEqual(SystemMemoryAccounting.used(total: total, unused: unused), total - unused)
        XCTAssertEqual(SystemMemoryAccounting.available(total: total, unused: unused, inactive: inactive), unused + inactive)
    }

    func testPhysicalMemoryCompositionExplainsResidualAndSumsToTotal() {
        let system = SystemSnapshot(
            totalMemory: 16_000,
            usedMemory: 15_000,
            unusedMemory: 1_000,
            wiredMemory: 2_500,
            compressedMemory: 1_500,
            activeMemory: 5_000,
            inactiveMemory: 4_000
        )
        let composition = PhysicalMemoryComposition(system: system)
        XCTAssertEqual(composition.systemOther, 2_000)
        XCTAssertEqual(composition.total, system.totalMemory)
    }

    func testMockNetworkEndpointsIncludeOriginalListeningPorts() async {
        let provider = MockProcessDataProvider()
        let endpoints = await provider.loadNetworkEndpoints(for: 41022)
        let ports = Set(endpoints.filter(\.isListening).map(\.localPort))
        XCTAssertEqual(ports, Set([2480, 5432, 7687, 8880]))
    }

    func testSystemPortScanKeepsOwningProcessIdentity() async {
        let provider = MockProcessDataProvider()
        let records = await NetworkPortScanner.scan(provider: provider)
        XCTAssertEqual(records.count, 5)
        XCTAssertTrue(records.allSatisfy { $0.process.pid == 41022 })
        XCTAssertEqual(Set(records.filter { $0.endpoint.isOpenPort }.map { $0.endpoint.localPort }), Set([2480, 5432, 7687, 8880]))
    }

    func testPageRefreshPolicyThresholdAndClockRollback() {
        let date = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(PageRefreshPolicy.isStale(nil, maxAge: 10, now: date))
        XCTAssertFalse(PageRefreshPolicy.isStale(date, maxAge: 10, now: date.addingTimeInterval(9.999)))
        XCTAssertTrue(PageRefreshPolicy.isStale(date, maxAge: 10, now: date.addingTimeInterval(10)))
        XCTAssertTrue(PageRefreshPolicy.isStale(date, maxAge: 10, now: date.addingTimeInterval(-1)))
    }

    @MainActor
    func testPortsPageRefreshThresholdDeduplicationAndManualOverride() async throws {
        let owner = MockProcessDataProvider.makeSample().processes[0]
        let provider = PortDiscoveryTestProvider(owner: owner)
        let store = ToppsStore(provider: provider)
        store.selectedSection = .ports
        store.refreshPageIfNeeded(.ports)
        XCTAssertTrue(store.isScanningPorts, "The first entry should discover ports")
        try await finishDiscovery(in: store)
        let updated = try XCTUnwrap(store.lastPortScan)
        let cached = store.networkEndpoints
        store.selectedIdentity = owner.identity
        store.searchText = "3000"
        store.refreshPageIfNeeded(.ports, now: updated.addingTimeInterval(9))
        XCTAssertFalse(store.isScanningPorts)
        for _ in 0..<20 { store.refreshPageIfNeeded(.ports, now: updated.addingTimeInterval(10)) }
        XCTAssertTrue(store.isScanningPorts)
        XCTAssertEqual(store.networkEndpoints, cached, "Keep cached rows during background refresh")
        XCTAssertEqual(store.selectedIdentity, owner.identity)
        try await finishDiscovery(in: store)
        let automaticScans = await provider.portScans
        XCTAssertEqual(automaticScans, 2, "Repeated visits must share the in-flight scan")
        XCTAssertEqual(store.searchText, "3000")
        XCTAssertEqual(store.selectedIdentity, owner.identity)
        store.scanPorts()
        XCTAssertTrue(store.isScanningPorts, "Scan Now must bypass the freshness threshold")
        try await finishDiscovery(in: store)
        let totalScans = await provider.portScans
        XCTAssertEqual(totalScans, 3)
    }

    @MainActor
    func testLLMPageRefreshRequiresExistingAnalysisAndFiveMinuteThreshold() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let provider = TestLLMFitProvider(completedAt: now)
        let store = ToppsStore(provider: MockProcessDataProvider(), llmFitProvider: provider)
        store.refreshPageIfNeeded(.llmFit, now: now)
        XCTAssertFalse(store.isAnalyzingLLMFit, "The first analysis must remain manual")
        let cached = testLLMAnalysis(at: now.addingTimeInterval(-299))
        store.llmFitAnalysis = cached
        store.refreshPageIfNeeded(.llmFit, now: now)
        XCTAssertFalse(store.isAnalyzingLLMFit)
        store.searchText = "my model filter"
        store.llmFitUseCase = .coding
        for _ in 0..<20 { store.refreshPageIfNeeded(.llmFit, now: now.addingTimeInterval(1)) }
        XCTAssertTrue(store.isAnalyzingLLMFit)
        XCTAssertEqual(store.llmFitAnalysis, cached, "Refreshing must leave the old results visible")
        try await finishDiscovery(in: store)
        let automaticRequests = await provider.requests
        XCTAssertEqual(automaticRequests, [.coding])
        XCTAssertEqual(store.searchText, "my model filter")
        store.analyzeLLMFit(now: now.addingTimeInterval(2))
        XCTAssertTrue(store.isAnalyzingLLMFit, "Manual analysis bypasses the threshold")
        try await finishDiscovery(in: store)
        let allRequests = await provider.requests
        XCTAssertEqual(allRequests, [.coding, .coding])
    }

    @MainActor
    func testFailedLLMAutoRefreshRetainsCacheAndHasRetryCooldown() async throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let provider = TestLLMFitProvider(completedAt: now, shouldFail: true)
        let store = ToppsStore(provider: MockProcessDataProvider(), llmFitProvider: provider)
        let cached = testLLMAnalysis(at: now.addingTimeInterval(-600))
        store.llmFitAnalysis = cached
        store.refreshPageIfNeeded(.llmFit, now: now)
        try await finishDiscovery(in: store)
        XCTAssertNotNil(store.llmFitError)
        XCTAssertEqual(store.llmFitAnalysis, cached)
        store.refreshPageIfNeeded(.llmFit, now: now.addingTimeInterval(299))
        XCTAssertFalse(store.isAnalyzingLLMFit, "Navigation must not repeatedly rerun a failing command")
        store.refreshPageIfNeeded(.llmFit, now: now.addingTimeInterval(300))
        XCTAssertTrue(store.isAnalyzingLLMFit)
        try await finishDiscovery(in: store)
        let requests = await provider.requests
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(store.llmFitAnalysis, cached)
    }

    @MainActor
    func testPageEntryDoesNotScanStorageLiveViewsOrUnavailableLLM() async throws {
        let provider = PortDiscoveryTestProvider(owner: MockProcessDataProvider.makeSample().processes[0])
        let llm = TestLLMFitProvider(installed: false)
        let store = ToppsStore(provider: provider, llmFitProvider: llm)
        store.llmFitAnalysis = testLLMAnalysis(at: .distantPast)
        for section in [MainSection.processes, .applications, .tree, .memory, .storage, .llmFit] {
            store.refreshPageIfNeeded(section)
        }
        XCTAssertFalse(store.isScanningStorage)
        XCTAssertFalse(store.isScanningPorts)
        XCTAssertFalse(store.isAnalyzingLLMFit)
        let samples = await provider.sampleCalls
        let scans = await provider.portScans
        let requests = await llm.requests
        XCTAssertEqual(samples, 0)
        XCTAssertEqual(scans, 0)
        XCTAssertTrue(requests.isEmpty)
    }

    @MainActor
    func testMemorySafetyPauseSuppressesAutomaticPageRefresh() async throws {
        let oldInterval = UserDefaults.standard.object(forKey: "refreshInterval")
        defer { UserDefaults.standard.set(oldInterval, forKey: "refreshInterval") }
        let source = MockProcessDataProvider.makeSample().processes[0]
        let oversized = replacing(source, pid: getpid(), physicalFootprint: AppMemorySafety.maximumFootprint)
        let llm = TestLLMFitProvider()
        let store = ToppsStore(provider: SoakProcessProvider(processes: [oversized]), llmFitProvider: llm)
        defer { store.stop() }
        await store.refresh()
        XCTAssertTrue(store.memorySafetyTripped)
        store.llmFitAnalysis = testLLMAnalysis(at: .distantPast)
        store.refreshPageIfNeeded(.ports)
        store.refreshPageIfNeeded(.llmFit)
        XCTAssertFalse(store.isScanningPorts)
        XCTAssertFalse(store.isAnalyzingLLMFit)
        XCTAssertNil(store.lastPortScan)
        // Explicit user actions are still available, but never launched by entry.
        store.scanPorts()
        store.analyzeLLMFit()
        XCTAssertTrue(store.isScanningPorts)
        XCTAssertTrue(store.isAnalyzingLLMFit)
        try await finishDiscovery(in: store)
    }

    @MainActor
    private func finishDiscovery(in store: ToppsStore) async throws {
        for _ in 0..<400 where store.isScanningPorts || store.isAnalyzingLLMFit {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertFalse(store.isScanningPorts)
        XCTAssertFalse(store.isAnalyzingLLMFit)
    }

    private func testLLMAnalysis(at date: Date) -> LLMFitAnalysis {
        LLMFitAnalysis(system: nil, recommendations: [], analyzedAt: date, executablePath: "/test/llmfit")
    }

    @MainActor
    func testPortScanDiscoversNewOwnerWhileMonitoringIsPaused() async throws {
        let owner = MockProcessDataProvider.makeSample().processes[0]
        let provider = PortDiscoveryTestProvider(owner: owner)
        let store = ToppsStore(provider: provider)
        let oldInterval = UserDefaults.standard.object(forKey: "refreshInterval")
        defer { UserDefaults.standard.set(oldInterval, forKey: "refreshInterval"); store.stop() }
        store.refreshInterval = .paused
        store.selectedSection = .ports
        await store.refresh()
        XCTAssertTrue(store.processes.isEmpty, "The paused snapshot predates the new server")
        // Exercise the window's selection-change handler, not just the store.
        let host = NSHostingView(rootView: MainWindowView().environmentObject(store))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }

        store.scanPorts()
        for _ in 0..<200 where store.isScanningPorts { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(store.isScanningPorts)
        XCTAssertEqual(store.networkEndpoints.first?.endpoint.localPort, 3000)
        XCTAssertEqual(store.networkEndpoints.first?.process.identity, owner.identity)
        XCTAssertNotNil(store.lastPortScan)
        XCTAssertTrue(store.processes.isEmpty, "A port scan must not replace the paused process snapshot")
        let sampleCalls = await provider.sampleCalls
        XCTAssertEqual(sampleCalls, 1, "A port scan must not advance regular sampling baselines")
        store.select(owner)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(store.selectedProcess?.identity, owner.identity, "Fresh port owners must be inspectable while paused")
        store.searchText = "3000"
        XCTAssertEqual(store.filteredNetworkEndpoints.count, 1)
        store.selectedSection = .processes
        try await Task.sleep(for: .milliseconds(50))
        store.lastPortScan = Date().addingTimeInterval(-11)
        store.selectedSection = .ports
        try await Task.sleep(for: .milliseconds(100))
        try await finishDiscovery(in: store)
        let scans = await provider.portScans
        XCTAssertEqual(scans, 2, "Returning to the rendered Ports page must refresh a stale snapshot")
        XCTAssertEqual(store.selectedIdentity, owner.identity)
    }

    func testPortScanDoesNotRequireTaskMetricsOrPositiveDescriptorCount() async throws {
        let owner = try XCTUnwrap(MockProcessDataProvider.makeSample().processes.first { !$0.isAccessible })
        XCTAssertEqual(owner.fileDescriptorCount, 0)
        let provider = PortDiscoveryTestProvider(owner: owner)
        let records = await NetworkPortScanner.scan(provider: provider)
        XCTAssertEqual(records.first?.process.identity, owner.identity)
        XCTAssertEqual(records.first?.endpoint.localPort, 3000)
    }

    func testPortNumbersAreNotFormattedAsQuantities() {
        for port: UInt16 in [3000, 3100, 5432, 65535] {
            let endpoint = NetworkEndpoint(fileDescriptor: 1, family: AF_INET6, socketType: SOCK_STREAM,
                                           protocolNumber: IPPROTO_TCP, tcpState: 1, localAddress: "::",
                                           localPort: port, remoteAddress: "::", remotePort: 0)
            XCTAssertEqual(endpoint.localPortDisplay, String(port))
            XCTAssertEqual(endpoint.localDisplay, "*:\(port)")
            XCTAssertFalse(endpoint.localPortDisplay.contains(","))
        }
    }

    func testNativePortScanFindsIPv6ListenerAndOwningProcess() async throws {
        let descriptor = socket(AF_INET6, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        defer { close(descriptor) }
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_loopback
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        guard bound == 0 else { return }
        XCTAssertEqual(listen(descriptor, 1), 0)
        var length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let status = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        XCTAssertEqual(status, 0)
        let port = UInt16(bigEndian: address.sin6_port)
        XCTAssertGreaterThan(port, 0)
        let records = await NetworkPortScanner.scan(provider: DarwinProcessDataProvider())
        let found = try XCTUnwrap(records.first {
            $0.process.pid == getpid() && $0.endpoint.fileDescriptor == descriptor && $0.endpoint.localPort == port
        })
        XCTAssertTrue(found.endpoint.isListening)
        XCTAssertEqual(found.endpoint.family, AF_INET6)
        XCTAssertEqual(found.endpoint.localAddress, "::1")
    }

    func testLLMFitParserReadsDocumentedJSONEnvelope() throws {
        let system = Data(#"{"system":{"cpu_name":"Apple M4 Pro","cpu_cores":14,"total_ram_gb":48,"available_ram_gb":37.5,"gpu_name":"Apple M4 Pro","gpu_vram_gb":48,"backend":"Metal","unified_memory":true}}"#.utf8)
        let recommendations = Data(#"{"models":[{"name":"Qwen/Qwen2.5-Coder-7B","provider":"Alibaba","parameter_count":"7.6B","params_b":7.6,"score":86.5,"score_components":{"quality":87,"speed":81.2,"fit":90.1,"context":88},"fit_level":"good","fit_label":"Good","run_mode":"gpu","run_mode_label":"GPU","category":"Coding","estimated_tps":42.5,"best_quant":"Q5_K_M","memory_required_gb":5.8,"memory_available_gb":37.5,"utilization_pct":15.5,"context_length":32768,"usable_context":32768,"runtime":"llamacpp","runtime_label":"llama.cpp","installed":false,"ollama_name":"qwen2.5-coder:7b","notes":["Comfortable fit"]}]}"#.utf8)
        let date = Date(timeIntervalSince1970: 123)
        let result = try LLMFitJSONParser.parse(systemData: system, recommendationData: recommendations, executablePath: "/opt/homebrew/bin/llmfit", date: date)

        XCTAssertEqual(result.system?.cpuName, "Apple M4 Pro")
        XCTAssertEqual(result.system?.availableRAMGB, 37.5)
        XCTAssertEqual(result.recommendations.first?.name, "Qwen/Qwen2.5-Coder-7B")
        XCTAssertEqual(result.recommendations.first?.fitLevel, "Good")
        XCTAssertEqual(result.recommendations.first?.estimatedTPS, 42.5)
        XCTAssertEqual(result.recommendations.first?.ollamaName, "qwen2.5-coder:7b")
        XCTAssertEqual(result.analyzedAt, date)
    }

    func testIdentityDetectsPIDReuse() {
        let first = ProcessIdentity(pid: 42, startTime: Date(timeIntervalSince1970: 100))
        let reused = ProcessIdentity(pid: 42, startTime: Date(timeIntervalSince1970: 200))
        XCTAssertNotEqual(first, reused)
        XCTAssertEqual(first, ProcessIdentity(pid: 42, startTime: first.startTime))
    }

    func testChromeHelpersAreGroupedWithChrome() {
        let sample = MockProcessDataProvider.makeSample()
        let groups = ProcessGroupingService.groups(from: sample.processes)
        let chrome = groups.first { $0.name == "Google Chrome" }
        XCTAssertEqual(chrome?.memberIDs.count, 3)
        XCTAssertEqual(chrome?.totalMemory, 5_450_000_000)
    }

    func testAncestryStopsAtCycle() {
        let base = MockProcessDataProvider.makeSample().processes[0]
        let a = replacing(base, pid: 10, ppid: 11)
        let b = replacing(base, pid: 11, ppid: 10)
        let ancestry = ProcessGroupingService.ancestry(of: a, among: [a, b])
        XCTAssertEqual(ancestry.map(\.pid), [11])
    }

    func testMissingParentIsHandled() {
        let process = MockProcessDataProvider.makeSample().processes[0]
        XCTAssertTrue(ProcessGroupingService.ancestry(of: process, among: [process]).isEmpty)
    }

    func testProtectedProcessUsesUnavailableMetrics() {
        let protected = MockProcessDataProvider.makeSample().processes.first { $0.name == "protected" }
        XCTAssertEqual(protected?.isAccessible, false)
        XCTAssertEqual(protected?.memory, 0)
    }

    func testHistoryRingBufferKeepsCapacity() async {
        let history = ProcessHistoryStore(capacity: 3)
        for tick in 1...6 { await history.ingest(MockProcessDataProvider.makeSample(tick: tick)) }
        let identity = MockProcessDataProvider.makeSample(tick: 1).processes[0].identity
        let points = await history.history(for: identity)
        XCTAssertLessThanOrEqual(points.count, 3)
    }

    func testProcessTableReloadsOnlyVisibleRowsWhenIdentitiesAreStable() {
        let sample = MockProcessDataProvider.makeSample().processes
        XCTAssertEqual(
            ProcessTableReloadStrategy.choose(previous: sample.map(\.identity), next: sample.map(\.identity)),
            .visibleRows
        )
        XCTAssertEqual(
            ProcessTableReloadStrategy.choose(previous: sample.map(\.identity), next: sample.reversed().map(\.identity)),
            .allRows
        )
    }

    func testAppMemorySafetyTripsAtOneGigabyte() {
        let source = MockProcessDataProvider.makeSample().processes[0]
        let belowLimit = replacing(source, pid: 99, physicalFootprint: AppMemorySafety.maximumFootprint - 1)
        let atLimit = replacing(source, pid: 99, physicalFootprint: AppMemorySafety.maximumFootprint)
        XCTAssertFalse(AppMemorySafety.shouldPause(currentPID: 99, processes: [belowLimit]))
        XCTAssertTrue(AppMemorySafety.shouldPause(currentPID: 99, processes: [atLimit]))
        XCTAssertFalse(AppMemorySafety.shouldPause(currentPID: 100, processes: [atLimit]))
    }

    func testMemoryGrowthMockIncreases() {
        let first = MockProcessDataProvider.makeSample(tick: 1).processes[0]
        let second = MockProcessDataProvider.makeSample(tick: 2).processes[0]
        XCTAssertEqual(second.memory - first.memory, 24_000_000)
        XCTAssertGreaterThan(second.memoryChangePerMinute, 0)
    }

    func testByteFormatting() {
        XCTAssertTrue(ByteFormat.string(1_500_000).contains("MB"))
        XCTAssertEqual(ByteFormat.signed(0), "—")
        XCTAssertTrue(ByteFormat.signed(1_500_000).hasPrefix("+"))
    }

    func testCSVExportQuotesCommandsAndHasTimestamp() throws {
        let data = ExportService.csv(processes: MockProcessDataProvider.makeSample().processes)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("snapshot_time,name,pid"))
        XCTAssertTrue(text.contains("41022"))
        XCTAssertTrue(text.contains("enterprise.cli"))
    }

    func testJSONExportRoundTrips() throws {
        let data = try ExportService.json(processes: MockProcessDataProvider.makeSample().processes)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual((object?["processes"] as? [[String: Any]])?.count, 7)
        XCTAssertNotNil(object?["timestamp"])
    }

    func testStorageScannerMeasuresAndClassifiesReproducibleFolders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("topps-storage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dependencies = root.appendingPathComponent("project/node_modules/package", isDirectory: true)
        let build = root.appendingPathComponent("project/target/debug", isDirectory: true)
        let appCache = root.appendingPathComponent("Library/Caches/com.example.editor", isDirectory: true)
        try FileManager.default.createDirectory(at: dependencies, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: appCache, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 8_192).write(to: dependencies.appendingPathComponent("index.js"))
        try Data(repeating: 2, count: 12_288).write(to: build.appendingPathComponent("binary"))
        try Data(repeating: 3, count: 4_096).write(to: appCache.appendingPathComponent("cache.db"))

        let snapshot = try await StorageScanner.scan(root: root)

        XCTAssertEqual(snapshot.fileCount, 3)
        XCTAssertGreaterThan(snapshot.allocatedBytes, 0)
        XCTAssertTrue(snapshot.entries.contains { $0.path.hasSuffix("node_modules") && $0.category == .dependencies })
        XCTAssertTrue(snapshot.entries.contains { $0.path.hasSuffix("target") && $0.category == .buildArtifacts })
        XCTAssertTrue(snapshot.entries.contains { $0.path.hasSuffix("com.example.editor") && $0.category == .cache })
    }

    func testStorageScannerKeepsMemoryBoundedAcrossLargeTrees() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("topps-storage-stress-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let directoryCount = 120
        let filesPerDirectory = 250
        for directoryIndex in 0..<directoryCount {
            try autoreleasepool {
                let directory = root.appendingPathComponent("project-\(directoryIndex)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
                for fileIndex in 0..<filesPerDirectory {
                    let path = directory.appendingPathComponent("artifact-\(fileIndex).dat").path
                    let descriptor = path.withCString { open($0, O_CREAT | O_EXCL | O_WRONLY, S_IRUSR | S_IWUSR) }
                    guard descriptor >= 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    close(descriptor)
                }
            }
        }

        let footprintBefore = currentPhysicalFootprint()
        let snapshot = try await StorageScanner.scan(root: root)
        let footprintAfter = currentPhysicalFootprint()
        let footprintGrowth = footprintAfter > footprintBefore ? footprintAfter - footprintBefore : 0

        XCTAssertEqual(snapshot.fileCount, UInt64(directoryCount * filesPerDirectory))
        XCTAssertLessThanOrEqual(snapshot.entries.count, 1_400)
        XCTAssertLessThan(
            footprintGrowth,
            96_000_000,
            "A storage scan should use memory proportional to retained results and path depth, not the number of files"
        )
    }

    func testStorageGrowthComparesExactPaths() throws {
        let previous = storageSnapshot(total: 1_000, entryBytes: 700, date: Date(timeIntervalSince1970: 100))
        let current = storageSnapshot(total: 1_450, entryBytes: 1_100, date: Date(timeIntervalSince1970: 200))

        let finding = try XCTUnwrap(StorageAnalysis.findings(current: current, previous: previous).first)
        XCTAssertEqual(finding.growth, 400)
        XCTAssertEqual(StorageAnalysis.rootGrowth(current: current, previous: previous), 450)
    }

    func testStorageRecommendationsStayConservative() throws {
        let cache = StorageEntry(path: "/tmp/project/.cache", kind: .directory, category: .cache, allocatedBytes: 500, logicalBytes: 500, fileCount: 1, modifiedAt: nil)
        let database = StorageEntry(path: "/tmp/production.sqlite", kind: .file, category: .largeFile, allocatedBytes: 5_000_000_000, logicalBytes: 5_000_000_000, fileCount: 1, modifiedAt: nil)
        let snapshot = StorageSnapshot(id: UUID(), rootPath: "/tmp", capturedAt: Date(), allocatedBytes: 5_000_000_500, logicalBytes: 5_000_000_500, fileCount: 2, unreadableItemCount: 0, duration: 0, entries: [cache, database])
        let findings = StorageAnalysis.findings(current: snapshot, previous: nil)

        XCTAssertEqual(try XCTUnwrap(findings.first { $0.entry.path == cache.path }).recommendation, .reviewDelete)
        XCTAssertEqual(try XCTUnwrap(findings.first { $0.entry.path == database.path }).recommendation, .inspect)
        XCTAssertEqual(StorageAnalysis.category(for: "/Users/test/.cargo", kind: .directory), .other)
        XCTAssertEqual(StorageAnalysis.category(for: "/Users/test/.cargo/registry", kind: .directory), .cache)
    }

    func testStorageHistoryPersistsAndCapsSnapshotsPerRoot() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("topps-history-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        let history = StorageHistoryStore(fileURL: file)
        for index in 0..<26 {
            _ = try await history.record(storageSnapshot(total: UInt64(index), entryBytes: UInt64(index), date: Date(timeIntervalSince1970: TimeInterval(index))))
        }

        let reloaded = await StorageHistoryStore(fileURL: file).snapshots()
        XCTAssertEqual(reloaded.count, 24)
        XCTAssertEqual(reloaded.first?.allocatedBytes, 25)
        XCTAssertEqual(reloaded.last?.allocatedBytes, 2)
    }

    private func storageSnapshot(total: UInt64, entryBytes: UInt64, date: Date) -> StorageSnapshot {
        StorageSnapshot(
            id: UUID(),
            rootPath: "/tmp/tracked-root",
            capturedAt: date,
            allocatedBytes: total,
            logicalBytes: total,
            fileCount: 1,
            unreadableItemCount: 0,
            duration: 0.1,
            entries: [
                StorageEntry(
                    path: "/tmp/tracked-root/project/target",
                    kind: .directory,
                    category: .buildArtifacts,
                    allocatedBytes: entryBytes,
                    logicalBytes: entryBytes,
                    fileCount: 1,
                    modifiedAt: date
                )
            ]
        )
    }

    private func currentPhysicalFootprint() -> UInt64 {
        var process = CPSProcessInfo()
        guard cps_read_process(getpid(), &process) == 1 else { return 0 }
        return process.physical_footprint > 0 ? process.physical_footprint : process.resident_bytes
    }

    private func replacing(_ source: ProcessSnapshot, pid: Int32, ppid: Int32? = nil, physicalFootprint: UInt64? = nil) -> ProcessSnapshot {
        let identity = ProcessIdentity(pid: pid, startTime: source.startTime)
        return ProcessSnapshot(identity: identity, pid: pid, ppid: ppid ?? source.ppid, processGroupID: source.processGroupID, userID: source.userID, user: source.user, name: source.name, executablePath: source.executablePath, command: source.command, bundleIdentifier: source.bundleIdentifier, startTime: source.startTime, state: source.state, threadCount: source.threadCount, fileDescriptorCount: source.fileDescriptorCount, cumulativeCPUTime: source.cumulativeCPUTime, cpuPercent: source.cpuPercent, cpuAverage10s: source.cpuAverage10s, cpuAverage60s: source.cpuAverage60s, residentMemory: source.residentMemory, physicalFootprint: physicalFootprint ?? source.physicalFootprint, peakPhysicalFootprint: source.peakPhysicalFootprint, memoryChange: source.memoryChange, memoryChangePerMinute: source.memoryChangePerMinute, bytesRead: source.bytesRead, bytesWritten: source.bytesWritten, diskReadDelta: source.diskReadDelta, diskWriteDelta: source.diskWriteDelta, pageFaults: source.pageFaults, architecture: source.architecture, isRosetta: source.isRosetta, isGUIApplication: source.isGUIApplication, isAccessible: source.isAccessible)
    }
}

private actor SoakProcessProvider: ProcessDataProvider {
    let processes: [ProcessSnapshot]
    private var tick = 0
    init(processes: [ProcessSnapshot]) { self.processes = processes }
    func sample() -> SamplingResult {
        tick += 1
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000 + Double(tick))
        let live = tick % 200 < 100 ? processes : Array(processes.dropLast(32))
        return SamplingResult(timestamp: timestamp, processes: live, system: SystemSnapshot(timestamp: timestamp))
    }
    func loadWorkingDirectory(for pid: Int32) -> String? { nil }
    func loadNetworkEndpoints(for pid: Int32) -> [NetworkEndpoint] { [] }
    func loadProcessesForPortScan() -> [ProcessSnapshot] { processes }
}

private actor PortDiscoveryTestProvider: ProcessDataProvider {
    let owner: ProcessSnapshot
    private(set) var sampleCalls = 0
    private(set) var portScans = 0
    init(owner: ProcessSnapshot) { self.owner = owner }
    func sample() -> SamplingResult {
        sampleCalls += 1
        return SamplingResult(timestamp: Date(), processes: [], system: SystemSnapshot())
    }
    func loadProcessesForPortScan() -> [ProcessSnapshot] { portScans += 1; return [owner] }
    func loadWorkingDirectory(for pid: Int32) -> String? { nil }
    func loadNetworkEndpoints(for pid: Int32) -> [NetworkEndpoint] {
        guard pid == owner.pid else { return [] }
        return [NetworkEndpoint(fileDescriptor: 12, family: AF_INET6, socketType: SOCK_STREAM,
                                protocolNumber: IPPROTO_TCP, tcpState: 1, localAddress: "::",
                                localPort: 3000, remoteAddress: "::", remotePort: 0)]
    }
}

private actor TestLLMFitProvider: LLMFitProviding {
    let installed: Bool
    let completedAt: Date
    let shouldFail: Bool
    private(set) var requests: [LLMFitUseCase] = []

    init(installed: Bool = true, completedAt: Date = Date(), shouldFail: Bool = false) {
        self.installed = installed
        self.completedAt = completedAt
        self.shouldFail = shouldFail
    }

    nonisolated func isInstalled() -> Bool { installed }

    func analyze(useCase: LLMFitUseCase) async throws -> LLMFitAnalysis {
        requests.append(useCase)
        try await Task.sleep(for: .milliseconds(30))
        if shouldFail { throw LLMFitServiceError.commandFailed("Test failure") }
        return LLMFitAnalysis(system: nil, recommendations: [], analyzedAt: completedAt, executablePath: "/test/llmfit")
    }
}
