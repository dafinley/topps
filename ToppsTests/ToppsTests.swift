import XCTest
@testable import Topps

final class ToppsTests: XCTestCase {
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

    private func replacing(_ source: ProcessSnapshot, pid: Int32, ppid: Int32) -> ProcessSnapshot {
        let identity = ProcessIdentity(pid: pid, startTime: source.startTime)
        return ProcessSnapshot(identity: identity, pid: pid, ppid: ppid, processGroupID: source.processGroupID, userID: source.userID, user: source.user, name: source.name, executablePath: source.executablePath, command: source.command, bundleIdentifier: source.bundleIdentifier, startTime: source.startTime, state: source.state, threadCount: source.threadCount, fileDescriptorCount: source.fileDescriptorCount, cumulativeCPUTime: source.cumulativeCPUTime, cpuPercent: source.cpuPercent, cpuAverage10s: source.cpuAverage10s, cpuAverage60s: source.cpuAverage60s, residentMemory: source.residentMemory, physicalFootprint: source.physicalFootprint, peakPhysicalFootprint: source.peakPhysicalFootprint, memoryChange: source.memoryChange, memoryChangePerMinute: source.memoryChangePerMinute, bytesRead: source.bytesRead, bytesWritten: source.bytesWritten, diskReadDelta: source.diskReadDelta, diskWriteDelta: source.diskWriteDelta, pageFaults: source.pageFaults, architecture: source.architecture, isRosetta: source.isRosetta, isGUIApplication: source.isGUIApplication, isAccessible: source.isAccessible)
    }
}
