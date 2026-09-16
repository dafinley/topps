import AppKit
import Darwin
import Foundation

actor DarwinProcessDataProvider: ProcessDataProvider {
    private struct Previous {
        let identity: ProcessIdentity
        let timestamp: Date
        let cpuTime: TimeInterval
        let memory: UInt64
        let bytesRead: UInt64
        let bytesWritten: UInt64
        var cpuHistory: [(Date, Double)]
    }

    private struct Metadata {
        let command: String?
        let bundleIdentifier: String?
        let isGUI: Bool
    }

    private var previous: [Int32: Previous] = [:]
    private var metadata: [ProcessIdentity: Metadata] = [:]
    private var usernames: [UInt32: String] = [:]
    private var previousSystemTicks: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?

    func sample() async -> SamplingResult {
        // Foundation metadata objects must drain per tick on the actor executor,
        // which does not have the main run loop's per-event autorelease pool.
        autoreleasepool { collectSample() }
    }

    func loadProcessesForPortScan() async -> [ProcessSnapshot] {
        autoreleasepool { collectSample(updateSamplingState: false).processes }
    }

    private func collectSample(updateSamplingState: Bool = true) -> SamplingResult {
        let timestamp = Date()
        var pids = [Int32](repeating: 0, count: 65_536)
        let count = pids.withUnsafeMutableBufferPointer { pointer in
            cps_list_pids(pointer.baseAddress, Int32(pointer.count))
        }
        guard count > 0 else {
            return SamplingResult(timestamp: timestamp, processes: [], system: updateSamplingState
                                  ? readSystem(timestamp: timestamp, processes: []) : SystemSnapshot(timestamp: timestamp))
        }

        var snapshots: [ProcessSnapshot] = []
        snapshots.reserveCapacity(Int(count))
        var seen: Set<ProcessIdentity> = []

        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = CPSProcessInfo()
            guard cps_read_process(pid, &info) == 1, info.start_seconds > 0 else { continue }
            let start = Date(timeIntervalSince1970: TimeInterval(info.start_seconds) + TimeInterval(info.start_microseconds) / 1_000_000)
            let identity = ProcessIdentity(pid: pid, startTime: start)
            seen.insert(identity)
            let name = cString(&info.name)
            let pathValue = cString(&info.path)
            let path = pathValue.isEmpty ? nil : pathValue
            let details = metadata[identity] ?? loadMetadata(pid: pid, path: path)
            metadata[identity] = details
            let cumulative = TimeInterval(info.user_time_ns &+ info.system_time_ns) / 1_000_000_000
            let footprint = info.physical_footprint > 0 ? info.physical_footprint : info.resident_bytes
            let old = previous[pid]
            let isSameProcess = old?.identity == identity
            let interval = isSameProcess ? max(0.001, timestamp.timeIntervalSince(old!.timestamp)) : 0
            let cpu = isSameProcess ? CPUDeltaCalculator.percentage(previousCPU: old!.cpuTime, currentCPU: cumulative, previousTime: old!.timestamp, currentTime: timestamp) : 0
            var cpuHistory = isSameProcess ? old!.cpuHistory : []
            cpuHistory.append((timestamp, cpu))
            cpuHistory.removeAll { timestamp.timeIntervalSince($0.0) > 60 }
            let avg10 = average(cpuHistory, since: timestamp.addingTimeInterval(-10))
            let avg60 = average(cpuHistory, since: timestamp.addingTimeInterval(-60))
            let memoryChange = isSameProcess ? signedDelta(footprint, old!.memory) : 0
            let readDelta = isSameProcess ? unsignedDelta(info.bytes_read, old!.bytesRead) : 0
            let writeDelta = isSameProcess ? unsignedDelta(info.bytes_written, old!.bytesWritten) : 0

            let snapshot = ProcessSnapshot(
                identity: identity,
                pid: pid,
                ppid: info.ppid,
                processGroupID: info.pgid,
                userID: info.uid,
                user: username(for: info.uid),
                name: name.isEmpty ? "PID \(pid)" : name,
                executablePath: path,
                command: details.command,
                bundleIdentifier: details.bundleIdentifier,
                startTime: start,
                state: state(from: info.status),
                threadCount: info.thread_count > 0 ? info.thread_count : nil,
                fileDescriptorCount: info.file_descriptor_count > 0 ? info.file_descriptor_count : nil,
                cumulativeCPUTime: cumulative,
                cpuPercent: cpu,
                cpuAverage10s: avg10,
                cpuAverage60s: avg60,
                residentMemory: info.resident_bytes > 0 ? info.resident_bytes : nil,
                physicalFootprint: info.physical_footprint > 0 ? info.physical_footprint : nil,
                peakPhysicalFootprint: info.peak_footprint > 0 ? info.peak_footprint : nil,
                memoryChange: memoryChange,
                memoryChangePerMinute: interval > 0 ? Double(memoryChange) / interval * 60 : 0,
                bytesRead: info.bytes_read > 0 ? info.bytes_read : nil,
                bytesWritten: info.bytes_written > 0 ? info.bytes_written : nil,
                diskReadDelta: readDelta,
                diskWriteDelta: writeDelta,
                pageFaults: info.page_faults > 0 ? info.page_faults : nil,
                architecture: architectureLabel,
                isRosetta: nil,
                isGUIApplication: details.isGUI,
                isAccessible: info.accessible != 0
            )
            snapshots.append(snapshot)
            if updateSamplingState {
                previous[pid] = Previous(identity: identity, timestamp: timestamp, cpuTime: cumulative, memory: footprint, bytesRead: info.bytes_read, bytesWritten: info.bytes_written, cpuHistory: cpuHistory)
            }
        }

        if updateSamplingState { previous = previous.filter { seen.contains($0.value.identity) } }
        metadata = metadata.filter { seen.contains($0.key) }
        return SamplingResult(timestamp: timestamp, processes: snapshots, system: updateSamplingState
                              ? readSystem(timestamp: timestamp, processes: snapshots) : SystemSnapshot(timestamp: timestamp))
    }

    func loadWorkingDirectory(for pid: Int32) async -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let result = buffer.withUnsafeMutableBufferPointer { cps_read_cwd(pid, $0.baseAddress, Int32($0.count)) }
        return result > 0 ? String(cString: buffer) : nil
    }

    func loadNetworkEndpoints(for pid: Int32) async -> [NetworkEndpoint] {
        var rawEndpoints = [CPSNetworkEndpoint](repeating: CPSNetworkEndpoint(), count: 1_024)
        let count = rawEndpoints.withUnsafeMutableBufferPointer {
            cps_read_network_endpoints(pid, $0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return [] }
        return rawEndpoints.prefix(Int(count)).map { raw in
            var mutable = raw
            let local = cString(&mutable.local_address)
            let remote = cString(&mutable.remote_address)
            return NetworkEndpoint(
                fileDescriptor: raw.file_descriptor,
                family: raw.family,
                socketType: raw.socket_type,
                protocolNumber: raw.protocol_number,
                tcpState: raw.tcp_state,
                localAddress: local,
                localPort: raw.local_port,
                remoteAddress: remote,
                remotePort: raw.remote_port
            )
        }.sorted {
            if $0.isListening != $1.isListening { return $0.isListening }
            if $0.localPort != $1.localPort { return $0.localPort < $1.localPort }
            return $0.fileDescriptor < $1.fileDescriptor
        }
    }

    private func loadMetadata(pid: Int32, path: String?) -> Metadata {
        var commandBuffer = [CChar](repeating: 0, count: 8192)
        let commandLength = commandBuffer.withUnsafeMutableBufferPointer { cps_read_command(pid, $0.baseAddress, Int32($0.count)) }
        let command = commandLength > 0 ? String(cString: commandBuffer) : nil
        let appURL = path.flatMap(applicationBundleURL)
        let bundleID = appURL.flatMap { Bundle(url: $0)?.bundleIdentifier }
        return Metadata(command: command, bundleIdentifier: bundleID, isGUI: appURL != nil)
    }

    private func applicationBundleURL(for path: String) -> URL? {
        guard let range = path.range(of: ".app/", options: .caseInsensitive) else { return nil }
        return URL(fileURLWithPath: String(path[..<range.upperBound].dropLast()))
    }

    private func username(for uid: UInt32) -> String {
        if let value = usernames[uid] { return value }
        let value = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? String(uid)
        usernames[uid] = value
        return value
    }

    private func state(from value: UInt32) -> ProcessState {
        switch value {
        case 1: .idle
        case 2: .running
        case 3: .sleeping
        case 4: .stopped
        case 5: .zombie
        default: .unknown
        }
    }

    private func readSystem(timestamp: Date, processes: [ProcessSnapshot]) -> SystemSnapshot {
        var raw = CPSSystemInfo()
        guard cps_read_system(&raw) == 1 else { return SystemSnapshot(timestamp: timestamp) }
        let current = (user: raw.cpu_user_ticks, system: raw.cpu_system_ticks, idle: raw.cpu_idle_ticks, nice: raw.cpu_nice_ticks)
        var user = 0.0, system = 0.0, idle = 100.0
        if let old = previousSystemTicks {
            let du = unsignedDelta(current.user, old.user) &+ unsignedDelta(current.nice, old.nice)
            let ds = unsignedDelta(current.system, old.system)
            let di = unsignedDelta(current.idle, old.idle)
            let total = du &+ ds &+ di
            if total > 0 {
                user = Double(du) / Double(total) * 100
                system = Double(ds) / Double(total) * 100
                idle = Double(di) / Double(total) * 100
            }
        }
        previousSystemTicks = current
        let unused = min(raw.total_memory, raw.free_memory)
        let available = SystemMemoryAccounting.available(total: raw.total_memory, unused: unused, inactive: raw.inactive_memory)
        return SystemSnapshot(
            timestamp: timestamp,
            totalMemory: raw.total_memory,
            usedMemory: SystemMemoryAccounting.used(total: raw.total_memory, unused: unused),
            availableMemory: available,
            unusedMemory: unused,
            wiredMemory: raw.wired_memory,
            compressedMemory: raw.compressed_memory,
            activeMemory: raw.active_memory,
            inactiveMemory: raw.inactive_memory,
            purgeableMemory: raw.purgeable_memory,
            speculativeMemory: raw.speculative_memory,
            swapUsed: raw.swap_used,
            userCPU: user,
            systemCPU: system,
            idleCPU: idle,
            processCount: processes.count,
            runningProcessCount: processes.filter { $0.state == .running }.count,
            threadCount: processes.reduce(0) { $0 + Int($1.threadCount ?? 0) }
        )
    }

    private func cString<T>(_ tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
        }
    }

    private func average(_ values: [(Date, Double)], since cutoff: Date) -> Double {
        let selected = values.filter { $0.0 >= cutoff }.map(\.1)
        return selected.isEmpty ? 0 : selected.reduce(0, +) / Double(selected.count)
    }

    private func signedDelta(_ current: UInt64, _ previous: UInt64) -> Int64 {
        if current >= previous { return Int64(clamping: current - previous) }
        return -Int64(clamping: previous - current)
    }

    private func unsignedDelta(_ current: UInt64, _ previous: UInt64) -> UInt64 { current >= previous ? current - previous : 0 }

    private var architectureLabel: String {
        #if arch(arm64)
        "Apple Silicon"
        #else
        "Intel"
        #endif
    }
}

actor MockProcessDataProvider: ProcessDataProvider {
    private var tick = 0
    func sample() async -> SamplingResult {
        tick += 1
        return Self.makeSample(tick: tick)
    }
    func loadProcessesForPortScan() async -> [ProcessSnapshot] { Self.makeSample(tick: tick).processes }
    func loadWorkingDirectory(for pid: Int32) async -> String? { pid == 41022 ? "/Applications/ATOMIC_EE_1.420.4.app/Contents/Resources" : nil }
    func loadNetworkEndpoints(for pid: Int32) async -> [NetworkEndpoint] {
        guard pid == 41022 else { return [] }
        return [
            NetworkEndpoint(fileDescriptor: 170, family: 30, socketType: 1, protocolNumber: 6, tcpState: 1, localAddress: "::", localPort: 5432, remoteAddress: "::", remotePort: 0),
            NetworkEndpoint(fileDescriptor: 171, family: 30, socketType: 1, protocolNumber: 6, tcpState: 1, localAddress: "127.0.0.1", localPort: 7687, remoteAddress: "::", remotePort: 0),
            NetworkEndpoint(fileDescriptor: 217, family: 30, socketType: 1, protocolNumber: 6, tcpState: 1, localAddress: "127.0.0.1", localPort: 2480, remoteAddress: "::", remotePort: 0),
            NetworkEndpoint(fileDescriptor: 219, family: 2, socketType: 1, protocolNumber: 6, tcpState: 1, localAddress: "0.0.0.0", localPort: 8880, remoteAddress: "0.0.0.0", remotePort: 0),
            NetworkEndpoint(fileDescriptor: 226, family: 2, socketType: 1, protocolNumber: 6, tcpState: 4, localAddress: "127.0.0.1", localPort: 62017, remoteAddress: "127.0.0.1", remotePort: 7687)
        ]
    }

    static func makeSample(tick: Int = 1) -> SamplingResult {
        let now = Date()
        let user = NSUserName()
        func process(_ pid: Int32, _ ppid: Int32, _ pgid: Int32, _ name: String, _ path: String?, _ command: String?, _ bundle: String?, _ cpu: Double, _ memory: UInt64, _ change: Int64, _ threads: UInt32, gui: Bool = false, accessible: Bool = true) -> ProcessSnapshot {
            let start = Date(timeIntervalSince1970: 1_720_000_000 - Double(pid % 100_000))
            return ProcessSnapshot(identity: ProcessIdentity(pid: pid, startTime: start), pid: pid, ppid: ppid, processGroupID: pgid, userID: getuid(), user: user, name: name, executablePath: path, command: command, bundleIdentifier: bundle, startTime: start, state: cpu > 1 ? .running : .sleeping, threadCount: threads, fileDescriptorCount: threads * 2, cumulativeCPUTime: 100, cpuPercent: cpu, cpuAverage10s: cpu * 0.9, cpuAverage60s: cpu * 0.75, residentMemory: memory / 12, physicalFootprint: memory, peakPhysicalFootprint: memory + 400_000_000, memoryChange: change, memoryChangePerMinute: Double(change) * 60, bytesRead: 4_000_000_000, bytesWritten: 800_000_000, diskReadDelta: 50_000, diskWriteDelta: 2_000, pageFaults: 12_000, architecture: "Apple Silicon", isRosetta: false, isGUIApplication: gui, isAccessible: accessible)
        }
        let growth = UInt64(tick) * 24_000_000
        let processes = [
            process(41022, 1, 40994, "python3.14", "/Applications/ATOMIC_EE_1.420.4.app/Contents/Resources/python/bin/python3.14", "/Applications/ATOMIC_EE_1.420.4.app/Contents/Resources/venv/bin/python -m enterprise.cli --host 0.0.0.0 --port 8880 --timeout-graceful-shutdown 10", "com.atomic.enterprise", 4.7, 14_100_000_000 + growth, 24_000_000, 92),
            process(200, 1, 200, "Google Chrome", "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "Google Chrome", "com.google.Chrome", 3.2, 1_820_000_000, 1_000_000, 44, gui: true),
            process(220, 200, 200, "Google Chrome Helper", "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper", "Google Chrome Helper --type=renderer", "com.google.Chrome.helper", 18.5, 2_650_000_000, 8_000_000, 38, gui: true),
            process(221, 200, 200, "Google Chrome Helper", "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper", "Google Chrome Helper --type=gpu-process", "com.google.Chrome.helper", 8.1, 980_000_000, -2_000_000, 22, gui: true),
            process(814, 1, 814, "Codex", "/Applications/Codex.app/Contents/MacOS/Codex", "/Applications/Codex.app/Contents/MacOS/Codex", "com.openai.codex", 24.3, 2_220_000_000, 4_500_000, 52, gui: true),
            process(901, 814, 814, "node", "/usr/local/bin/node", "node /Users/dev/project/server.js", nil, 82.4, 1_180_000_000 + growth / 2, 12_000_000, 68),
            process(77, 1, 77, "protected", nil, nil, nil, 0, 0, 0, 0, accessible: false)
        ]
        return SamplingResult(timestamp: now, processes: processes, system: SystemSnapshot(timestamp: now, totalMemory: 32_000_000_000, usedMemory: 31_200_000_000, availableMemory: 6_400_000_000, unusedMemory: 800_000_000, wiredMemory: 3_100_000_000, compressedMemory: 4_200_000_000, activeMemory: 10_400_000_000, inactiveMemory: 5_600_000_000, purgeableMemory: 900_000_000, speculativeMemory: 300_000_000, swapUsed: 8_600_000_000, userCPU: 23, systemCPU: 12, idleCPU: 65, processCount: 643, runningProcessCount: 11, threadCount: 3_421))
    }
}
