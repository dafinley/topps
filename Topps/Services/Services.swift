import AppKit
import Darwin
import Foundation

protocol ProcessDataProvider: Sendable {
    func sample() async -> SamplingResult
    /// Fresh process discovery, independent of paused UI snapshots and sampling baselines.
    func loadProcessesForPortScan() async -> [ProcessSnapshot]
    func loadWorkingDirectory(for pid: Int32) async -> String?
    func loadNetworkEndpoints(for pid: Int32) async -> [NetworkEndpoint]
}

enum CPUDeltaCalculator {
    static func percentage(previousCPU: TimeInterval, currentCPU: TimeInterval, previousTime: Date, currentTime: Date) -> Double {
        let wall = currentTime.timeIntervalSince(previousTime)
        let cpu = currentCPU - previousCPU
        guard wall > 0, cpu >= 0 else { return 0 }
        return min(9_999, cpu / wall * 100)
    }
}

enum SystemMemoryAccounting {
    static func used(total: UInt64, unused: UInt64) -> UInt64 {
        total > unused ? total - unused : 0
    }

    static func available(total: UInt64, unused: UInt64, inactive: UInt64) -> UInt64 {
        min(total, unused &+ inactive)
    }
}

actor ProcessHistoryStore {
    // Reference-owned buffers are mutated in place. Extracting an Array from the
    // dictionary before every append triggered copy-on-write for every process.
    private final class Buffer {
        var points: [HistoryPoint] = []
        var next = 0
        func append(_ point: HistoryPoint, capacity: Int) {
            if points.count < capacity { points.append(point) }
            else { points[next] = point; next = (next + 1) % capacity }
        }
        func ordered() -> [HistoryPoint] {
            guard next > 0 else { return points }
            return Array(points[next...]) + points[..<next]
        }
    }
    private var storage: [ProcessIdentity: Buffer] = [:]
    private var lastSeen: [ProcessIdentity: Date] = [:]
    let capacity: Int

    init(capacity: Int = 300) { self.capacity = max(1, capacity) }

    func ingest(_ result: SamplingResult) {
        let now = result.timestamp
        let stale = lastSeen.filter { now.timeIntervalSince($0.value) > 60 }.map(\.key)
        for key in stale { storage[key] = nil; lastSeen[key] = nil }
        for process in result.processes {
            let buffer: Buffer
            if let existing = storage[process.identity] { buffer = existing }
            else { buffer = Buffer(); storage[process.identity] = buffer }
            buffer.append(HistoryPoint(
                timestamp: now,
                cpu: process.cpuPercent,
                footprint: process.physicalFootprint ?? 0,
                resident: process.residentMemory ?? 0,
                readDelta: process.diskReadDelta,
                writeDelta: process.diskWriteDelta
            ), capacity: capacity)
            lastSeen[process.identity] = now
        }
    }

    func history(for identity: ProcessIdentity) -> [HistoryPoint] { storage[identity]?.ordered() ?? [] }
}

enum ProcessGroupingService {
    static func groups(from processes: [ProcessSnapshot]) -> [ProcessGroup] {
        let processByPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        var buckets: [String: [ProcessSnapshot]] = [:]
        var names: [String: String] = [:]
        var bundleIDs: [String: String] = [:]

        for process in processes {
            let root = applicationRoot(for: process, processByPID: processByPID)
            let key: String
            let displayName: String
            if let bundle = root.bundleIdentifier ?? process.bundleIdentifier {
                key = "bundle:\(bundle)"
                displayName = friendlyName(root)
                bundleIDs[key] = bundle
            } else if let appName = appNameFromPath(root.executablePath ?? process.executablePath) {
                key = "app:\(appName.lowercased())"
                displayName = appName
            } else {
                let executable = canonicalExecutable(root.executablePath ?? process.executablePath ?? root.name)
                key = "exec:\(executable)"
                displayName = commandFamilyName(root)
            }
            buckets[key, default: []].append(process)
            names[key] = displayName
        }

        return buckets.compactMap { key, members in
            guard let highest = members.max(by: { $0.memory < $1.memory }) else { return nil }
            return ProcessGroup(
                id: key,
                name: names[key] ?? highest.name,
                bundleIdentifier: bundleIDs[key],
                memberIDs: members.map(\.identity),
                totalCPU: members.reduce(0) { $0 + $1.cpuPercent },
                totalMemory: members.reduce(0) { $0 &+ $1.memory },
                memoryGrowth: members.reduce(0) { $0 &+ $1.memoryChange },
                totalThreads: members.reduce(0) { $0 &+ UInt64($1.threadCount ?? 0) },
                highestConsumer: highest
            )
        }.sorted { $0.totalMemory > $1.totalMemory }
    }

    static func ancestry(of process: ProcessSnapshot, among processes: [ProcessSnapshot]) -> [ProcessSnapshot] {
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        var result: [ProcessSnapshot] = []
        var seen: Set<Int32> = [process.pid]
        var parent = process.ppid
        while parent > 0, let value = byPID[parent], !seen.contains(parent) {
            result.append(value)
            seen.insert(parent)
            parent = value.ppid
        }
        return result
    }

    private static func applicationRoot(for process: ProcessSnapshot, processByPID: [Int32: ProcessSnapshot]) -> ProcessSnapshot {
        var current = process
        var seen: Set<Int32> = [current.pid]
        for _ in 0..<24 {
            let looksLikeHelper = current.name.localizedCaseInsensitiveContains("helper") || current.bundleIdentifier?.localizedCaseInsensitiveContains(".helper") == true
            if !looksLikeHelper, current.bundleIdentifier != nil || appNameFromPath(current.executablePath) != nil { return current }
            guard let parent = processByPID[current.ppid], !seen.contains(parent.pid), parent.pid != 1 else { break }
            current = parent
            seen.insert(parent.pid)
        }
        return current
    }

    private static func appNameFromPath(_ path: String?) -> String? {
        guard let path, let range = path.range(of: ".app/", options: .caseInsensitive) else { return nil }
        let prefix = path[..<range.upperBound].dropLast()
        return URL(fileURLWithPath: String(prefix)).deletingPathExtension().lastPathComponent
    }

    private static func canonicalExecutable(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func commandFamilyName(_ process: ProcessSnapshot) -> String {
        let lower = process.displayCommand.lowercased()
        if lower.contains("python") { return "Python" }
        if lower.contains("node") { return "Node.js" }
        if lower.contains("bun") { return "Bun" }
        if lower.contains("docker") { return "Docker" }
        return process.name
    }

    private static func friendlyName(_ process: ProcessSnapshot) -> String {
        appNameFromPath(process.executablePath) ?? process.name
    }
}

enum ExportService {
    static func csv(processes: [ProcessSnapshot], timestamp: Date = Date()) -> Data {
        let header = "snapshot_time,name,pid,ppid,pgid,user,state,cpu_percent,memory_bytes,memory_change_bytes,threads,fd_count,start_time,command,path,bundle_id\n"
        let iso = ISO8601DateFormatter()
        var rows: [String] = []
        rows.reserveCapacity(processes.count)
        for process in processes {
            let fields: [String] = [
                iso.string(from: timestamp), process.name, String(process.pid), String(process.ppid),
                String(process.processGroupID), process.user, process.state.rawValue,
                String(format: "%.2f", process.cpuPercent), String(process.memory), String(process.memoryChange),
                process.threadCount.map(String.init) ?? "", process.fileDescriptorCount.map(String.init) ?? "",
                iso.string(from: process.startTime), process.command ?? "", process.executablePath ?? "", process.bundleIdentifier ?? ""
            ]
            rows.append(fields.map { csvEscape($0) }.joined(separator: ","))
        }
        return Data((header + rows.joined(separator: "\n") + "\n").utf8)
    }

    static func json(processes: [ProcessSnapshot], timestamp: Date = Date()) throws -> Data {
        struct Payload: Encodable { let timestamp: Date; let processes: [ProcessSnapshot] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(Payload(timestamp: timestamp, processes: processes))
    }

    static func tsv(processes: [ProcessSnapshot]) -> String {
        processes.map { "\($0.name)\t\($0.pid)\t\(String(format: "%.1f%%", $0.cpuPercent))\t\(ByteFormat.string($0.memory))\t\($0.displayCommand)" }.joined(separator: "\n")
    }

    private static func csvEscape(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}

enum DiagnosticKind: String, CaseIterable, Identifiable {
    case vmmap = "Memory Map Summary"
    case sample = "5 Second Sample"
    case files = "Open Files"
    case network = "Network Connections"
    var id: String { rawValue }
    var executable: URL {
        switch self {
        case .vmmap: URL(fileURLWithPath: "/usr/bin/vmmap")
        case .sample: URL(fileURLWithPath: "/usr/bin/sample")
        case .files, .network: URL(fileURLWithPath: "/usr/sbin/lsof")
        }
    }
    func arguments(pid: Int32) -> [String] {
        switch self {
        case .vmmap: ["-summary", String(pid)]
        case .sample: [String(pid), "5"]
        case .files: ["-p", String(pid)]
        case .network: ["-Pan", "-p", String(pid), "-i"]
        }
    }
}

struct DiagnosticResult: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let pid: Int32
    let timestamp: Date
    let output: String
    let succeeded: Bool
}

enum DiagnosticRunner {
    static func run(_ kind: DiagnosticKind, pid: Int32) async -> DiagnosticResult {
        await Task.detached(priority: .userInitiated) {
            let process = Foundation.Process()
            let pipe = Pipe()
            process.executableURL = kind.executable
            process.arguments = kind.arguments(pid: pid)
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let text = String(data: data, encoding: .utf8) ?? "Output was not valid UTF-8."
                return DiagnosticResult(title: kind.rawValue, pid: pid, timestamp: Date(), output: text, succeeded: process.terminationStatus == 0)
            } catch {
                return DiagnosticResult(title: kind.rawValue, pid: pid, timestamp: Date(), output: error.localizedDescription, succeeded: false)
            }
        }.value
    }
}

enum ProcessSignalService {
    static func canSignal(_ process: ProcessSnapshot) -> Bool { process.userID == getuid() && process.pid != 1 }
    static func send(_ signal: Int32, to process: ProcessSnapshot) throws {
        guard canSignal(process) else { throw CocoaError(.fileWriteNoPermission) }
        if Darwin.kill(process.pid, signal) != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM) }
    }
}
