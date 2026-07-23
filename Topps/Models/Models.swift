import Foundation

struct ProcessIdentity: Hashable, Codable, Sendable, Identifiable {
    let pid: Int32
    let startTime: Date
    var id: String { "\(pid)-\(startTime.timeIntervalSince1970)" }
}

enum ProcessState: String, Codable, CaseIterable, Sendable {
    case running = "Running"
    case sleeping = "Sleeping"
    case stopped = "Stopped"
    case zombie = "Zombie"
    case idle = "Idle"
    case unknown = "Unknown"
}

struct ProcessSnapshot: Identifiable, Hashable, Codable, Sendable {
    let identity: ProcessIdentity
    var id: ProcessIdentity { identity }
    let pid: Int32
    let ppid: Int32
    let processGroupID: Int32
    let userID: UInt32
    let user: String
    let name: String
    let executablePath: String?
    let command: String?
    let bundleIdentifier: String?
    let startTime: Date
    let state: ProcessState
    let threadCount: UInt32?
    let fileDescriptorCount: UInt32?
    let cumulativeCPUTime: TimeInterval
    let cpuPercent: Double
    let cpuAverage10s: Double
    let cpuAverage60s: Double
    let residentMemory: UInt64?
    let physicalFootprint: UInt64?
    let peakPhysicalFootprint: UInt64?
    let memoryChange: Int64
    let memoryChangePerMinute: Double
    let bytesRead: UInt64?
    let bytesWritten: UInt64?
    let diskReadDelta: UInt64
    let diskWriteDelta: UInt64
    let pageFaults: UInt64?
    let architecture: String
    let isRosetta: Bool?
    let isGUIApplication: Bool
    let isAccessible: Bool

    var memory: UInt64 { physicalFootprint ?? residentMemory ?? 0 }
    var footprintResidentRatio: Double? {
        guard let footprint = physicalFootprint, let resident = residentMemory, resident > 0 else { return nil }
        return Double(footprint) / Double(resident)
    }
    var hasLedgerHeavyFootprint: Bool {
        guard let footprint = physicalFootprint, let resident = residentMemory, footprint > resident else { return false }
        return footprint - resident > 500_000_000 && footprintResidentRatio.map { $0 > 1.5 } == true
    }
    var isDetached: Bool { ppid == 1 && pid != 1 }
    var runtime: TimeInterval { max(0, Date().timeIntervalSince(startTime)) }
    var displayCommand: String { command?.isEmpty == false ? command! : (executablePath ?? name) }
}

struct ProcessGroup: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let bundleIdentifier: String?
    let memberIDs: [ProcessIdentity]
    let totalCPU: Double
    let totalMemory: UInt64
    let memoryGrowth: Int64
    let totalThreads: UInt64
    let highestConsumer: ProcessSnapshot
}

struct HistoryPoint: Hashable, Sendable {
    let timestamp: Date
    let cpu: Double
    let footprint: UInt64
    let resident: UInt64
    let readDelta: UInt64
    let writeDelta: UInt64
}

struct NetworkEndpoint: Identifiable, Hashable, Sendable {
    let fileDescriptor: Int32
    let family: Int32
    let socketType: Int32
    let protocolNumber: Int32
    let tcpState: Int32
    let localAddress: String
    let localPort: UInt16
    let remoteAddress: String
    let remotePort: UInt16

    var id: String { "\(fileDescriptor)-\(protocolNumber)-\(localAddress)-\(localPort)-\(remoteAddress)-\(remotePort)" }
    var protocolName: String {
        switch protocolNumber {
        case 6: "TCP"
        case 17: "UDP"
        default: "IP \(protocolNumber)"
        }
    }
    var stateName: String {
        guard protocolNumber == 6 else { return "Datagram" }
        return switch tcpState {
        case 1: "Listening"
        case 2: "SYN sent"
        case 3: "SYN received"
        case 4: "Established"
        case 5: "Close wait"
        case 6: "FIN wait 1"
        case 7: "Closing"
        case 8: "Last ACK"
        case 9: "FIN wait 2"
        case 10: "Time wait"
        default: "Closed"
        }
    }
    var isListening: Bool { protocolNumber == 6 && tcpState == 1 }
    var localDisplay: String { Self.endpoint(address: localAddress, port: localPort) }
    var remoteDisplay: String { remotePort == 0 ? "—" : Self.endpoint(address: remoteAddress, port: remotePort) }

    private static func endpoint(address: String, port: UInt16) -> String {
        let host = address == "0.0.0.0" || address == "::" || address.isEmpty ? "*" : address
        return host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)"
    }
}

struct SystemSnapshot: Sendable {
    var timestamp = Date()
    var totalMemory: UInt64 = 0
    var usedMemory: UInt64 = 0
    var availableMemory: UInt64 = 0
    var unusedMemory: UInt64 = 0
    var wiredMemory: UInt64 = 0
    var compressedMemory: UInt64 = 0
    var activeMemory: UInt64 = 0
    var inactiveMemory: UInt64 = 0
    var purgeableMemory: UInt64 = 0
    var speculativeMemory: UInt64 = 0
    var swapUsed: UInt64 = 0
    var userCPU: Double = 0
    var systemCPU: Double = 0
    var idleCPU: Double = 100
    var processCount: Int = 0
    var runningProcessCount: Int = 0
    var threadCount: Int = 0
    var totalCPU: Double { userCPU + systemCPU }
    var pressure: MemoryPressure {
        guard totalMemory > 0 else { return .normal }
        let ratio = Double(usedMemory) / Double(totalMemory)
        if ratio > 0.92 || compressedMemory > totalMemory / 3 { return .critical }
        if ratio > 0.80 || compressedMemory > totalMemory / 6 { return .warning }
        return .normal
    }
}

struct PhysicalMemoryComposition: Equatable, Sendable {
    let wired: UInt64
    let compressed: UInt64
    let active: UInt64
    let inactive: UInt64
    let systemOther: UInt64
    let unused: UInt64

    init(system: SystemSnapshot) {
        let total = system.totalMemory
        let used = min(total, system.usedMemory)
        var remainingUsed = used
        func take(_ requested: UInt64, from remaining: inout UInt64) -> UInt64 {
            let value = min(requested, remaining)
            remaining -= value
            return value
        }
        wired = take(system.wiredMemory, from: &remainingUsed)
        compressed = take(system.compressedMemory, from: &remainingUsed)
        active = take(system.activeMemory, from: &remainingUsed)
        inactive = take(system.inactiveMemory, from: &remainingUsed)
        systemOther = remainingUsed
        unused = total - used
    }

    var total: UInt64 { wired + compressed + active + inactive + systemOther + unused }
}

enum MemoryPressure: String, Sendable {
    case normal = "Normal"
    case warning = "Elevated"
    case critical = "Critical"
}

struct SamplingResult: Sendable {
    let timestamp: Date
    let processes: [ProcessSnapshot]
    let system: SystemSnapshot
}

enum RefreshInterval: Double, CaseIterable, Identifiable {
    case halfSecond = 0.5
    case oneSecond = 1
    case twoSeconds = 2
    case fiveSeconds = 5
    case paused = 0
    var id: Double { rawValue }
    var label: String { self == .paused ? "Paused" : "\(rawValue.formatted()) s" }
}

enum ProcessFilter: String, CaseIterable, Identifiable {
    case all = "All Processes"
    case myProcesses = "My Processes"
    case applications = "Applications"
    case commandLine = "Command Line"
    case detached = "Detached"
    var id: String { rawValue }
}

enum ProcessSort: String, CaseIterable, Identifiable {
    case memory = "Footprint"
    case cpu = "CPU"
    case growth = "Growth"
    case name = "Name"
    case pid = "PID"
    case runtime = "Runtime"
    var id: String { rawValue }
}

enum MainSection: String, CaseIterable, Identifiable {
    case processes = "Processes"
    case applications = "Applications"
    case tree = "Process Tree"
    case memory = "Memory Investigation"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .processes: "list.bullet.rectangle"
        case .applications: "square.stack.3d.up"
        case .tree: "point.3.connected.trianglepath.dotted"
        case .memory: "memorychip"
        }
    }
}

enum ByteFormat {
    static func string(_ value: UInt64, exact: Bool = false) -> String {
        if exact { return value.formatted() + " B" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(clamping: value))
    }

    static func signed(_ value: Int64) -> String {
        if value == 0 { return "—" }
        let prefix = value > 0 ? "+" : "−"
        return prefix + string(UInt64(value.magnitude))
    }
}

enum DurationFormat {
    static func string(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        if minutes > 0 { return "\(minutes)m \(seconds % 60)s" }
        return "\(seconds)s"
    }
}
