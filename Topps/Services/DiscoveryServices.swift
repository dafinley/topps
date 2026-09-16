import Foundation

enum PageRefreshPolicy {
    static let portsMaxAge: TimeInterval = 10
    static let llmFitMaxAge: TimeInterval = 5 * 60

    static func isStale(_ updatedAt: Date?, maxAge: TimeInterval, now: Date) -> Bool {
        guard let updatedAt else { return true }
        let age = now.timeIntervalSince(updatedAt)
        // Treat clock rollback as stale instead of postponing refresh indefinitely.
        return age < 0 || age >= maxAge
    }
}

protocol LLMFitProviding: Sendable {
    func isInstalled() -> Bool
    func analyze(useCase: LLMFitUseCase) async throws -> LLMFitAnalysis
}

struct LocalLLMFitProvider: LLMFitProviding {
    func isInstalled() -> Bool { LLMFitService.executableURL() != nil }
    func analyze(useCase: LLMFitUseCase) async throws -> LLMFitAnalysis {
        try await LLMFitService.analyze(useCase: useCase)
    }
}

enum NetworkPortScanner {
    static func scan(provider: any ProcessDataProvider) async -> [ProcessNetworkEndpoint] {
        let processes = await provider.loadProcessesForPortScan()
        var records: [ProcessNetworkEndpoint] = []
        // Task metrics and socket descriptors have different access rules. Neither
        // a missing metric nor an old descriptor count proves there are no sockets.
        for process in processes {
            guard !Task.isCancelled else { return [] }
            let endpoints = await provider.loadNetworkEndpoints(for: process.pid)
            guard !Task.isCancelled else { return [] }
            records.append(contentsOf: endpoints.map { ProcessNetworkEndpoint(process: process, endpoint: $0) })
        }
        return records.sorted {
            if $0.endpoint.isOpenPort != $1.endpoint.isOpenPort { return $0.endpoint.isOpenPort }
            if $0.endpoint.localPort != $1.endpoint.localPort { return $0.endpoint.localPort < $1.endpoint.localPort }
            if $0.process.name != $1.process.name { return $0.process.name.localizedCaseInsensitiveCompare($1.process.name) == .orderedAscending }
            return $0.process.pid < $1.process.pid
        }
    }
}

enum LLMFitServiceError: LocalizedError {
    case executableNotFound
    case commandFailed(String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "llmfit is not installed. Install it with Homebrew, then run the analysis again."
        case .commandFailed(let message):
            "llmfit could not complete the analysis: \(message)"
        case .invalidOutput(let message):
            "Topps could not read llmfit's JSON output: \(message)"
        }
    }
}

enum LLMFitService {
    static let installCommand = "brew install llmfit"

    static func executableURL(fileManager: FileManager = .default, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser.path
        var candidates = [
            "/opt/homebrew/bin/llmfit",
            "/usr/local/bin/llmfit",
            "/opt/local/bin/llmfit",
            "\(home)/.local/bin/llmfit",
            "\(home)/.cargo/bin/llmfit"
        ]
        candidates.append(contentsOf: (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/llmfit" })
        var seen = Set<String>()
        return candidates.first { path in
            guard seen.insert(path).inserted else { return false }
            return fileManager.isExecutableFile(atPath: path)
        }.map { URL(fileURLWithPath: $0) }
    }

    static func analyze(useCase: LLMFitUseCase, limit: Int = 100) async throws -> LLMFitAnalysis {
        guard let executable = executableURL() else { throw LLMFitServiceError.executableNotFound }
        let systemData = try await run(executable: executable, arguments: ["--json", "system"])
        let recommendationData = try await run(
            executable: executable,
            arguments: ["recommend", "--json", "--use-case", useCase.rawValue, "--min-fit", "marginal", "--limit", String(limit)]
        )
        return try LLMFitJSONParser.parse(
            systemData: systemData,
            recommendationData: recommendationData,
            executablePath: executable.path
        )
    }

    private static func run(executable: URL, arguments: [String]) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let directory = fileManager.temporaryDirectory.appendingPathComponent("topps-llmfit-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: directory) }

            let outputURL = directory.appendingPathComponent("stdout.json")
            let errorURL = directory.appendingPathComponent("stderr.txt")
            guard fileManager.createFile(atPath: outputURL.path, contents: nil),
                  fileManager.createFile(atPath: errorURL.path, contents: nil) else {
                throw LLMFitServiceError.commandFailed("Could not create temporary output files.")
            }
            let output = try FileHandle(forWritingTo: outputURL)
            let error = try FileHandle(forWritingTo: errorURL)
            defer { try? output.close(); try? error.close() }

            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = error
            try process.run()
            process.waitUntilExit()
            try output.synchronize()
            try error.synchronize()

            guard process.terminationStatus == 0 else {
                let errorData = (try? Data(contentsOf: errorURL)) ?? Data()
                let message = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw LLMFitServiceError.commandFailed(message?.isEmpty == false ? message! : "Exited with status \(process.terminationStatus).")
            }
            return try Data(contentsOf: outputURL)
        }.value
    }
}

enum LLMFitJSONParser {
    static func parse(systemData: Data, recommendationData: Data, executablePath: String, date: Date = Date()) throws -> LLMFitAnalysis {
        let systemRoot = try dictionary(from: systemData)
        let recommendationRoot = try dictionary(from: recommendationData)
        let systemObject = (systemRoot["system"] as? [String: Any]) ?? systemRoot
        let system = parseSystem(systemObject)
        guard let modelObjects = recommendationRoot["models"] as? [[String: Any]] else {
            throw LLMFitServiceError.invalidOutput("The response did not contain a models array.")
        }
        let models = modelObjects.compactMap(parseRecommendation).sorted { $0.score > $1.score }
        guard !models.isEmpty else { throw LLMFitServiceError.invalidOutput("No runnable model recommendations were returned.") }
        return LLMFitAnalysis(system: system, recommendations: models, analyzedAt: date, executablePath: executablePath)
    }

    private static func dictionary(from data: Data) throws -> [String: Any] {
        do {
            guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw LLMFitServiceError.invalidOutput("The root value was not an object.")
            }
            return value
        } catch let error as LLMFitServiceError {
            throw error
        } catch {
            throw LLMFitServiceError.invalidOutput(error.localizedDescription)
        }
    }

    private static func parseSystem(_ value: [String: Any]) -> LLMFitSystem? {
        guard let totalRAM = number(value["total_ram_gb"]) else { return nil }
        return LLMFitSystem(
            cpuName: string(value["cpu_name"]) ?? "Unknown CPU",
            cpuCores: integer(value["cpu_cores"]) ?? 0,
            totalRAMGB: totalRAM,
            availableRAMGB: number(value["available_ram_gb"]) ?? totalRAM,
            gpuName: string(value["gpu_name"]),
            gpuVRAMGB: number(value["gpu_vram_gb"]),
            backend: string(value["backend"]) ?? "Unknown",
            unifiedMemory: boolean(value["unified_memory"]) ?? false
        )
    }

    private static func parseRecommendation(_ value: [String: Any]) -> LLMFitRecommendation? {
        guard let name = string(value["name"]) else { return nil }
        let components = value["score_components"] as? [String: Any] ?? [:]
        let fitLevel = string(value["fit_label"]) ?? string(value["fit_level"]) ?? "Unknown"
        let runMode = string(value["run_mode_label"]) ?? string(value["run_mode"]) ?? "Unknown"
        let runtime = string(value["runtime_label"]) ?? string(value["runtime"]) ?? "Unknown"
        let paramsB = number(value["params_b"])
        return LLMFitRecommendation(
            name: name,
            provider: string(value["provider"]) ?? "Unknown",
            parameterCount: string(value["parameter_count"]) ?? paramsB.map { String(format: "%.1fB", $0) } ?? "—",
            paramsB: paramsB,
            score: number(value["score"]) ?? 0,
            qualityScore: number(components["quality"]),
            speedScore: number(components["speed"]),
            fitScore: number(components["fit"]),
            contextScore: number(components["context"]),
            fitLevel: fitLevel,
            runMode: runMode,
            category: string(value["category"]) ?? string(value["use_case"]) ?? "General",
            estimatedTPS: number(value["estimated_tps"]) ?? 0,
            bestQuant: string(value["best_quant"]) ?? "—",
            memoryRequiredGB: number(value["memory_required_gb"]) ?? 0,
            memoryAvailableGB: number(value["memory_available_gb"]) ?? 0,
            utilizationPercent: number(value["utilization_pct"]) ?? 0,
            contextLength: integer(value["context_length"]) ?? 0,
            usableContext: integer(value["usable_context"]),
            runtime: runtime,
            installed: boolean(value["installed"]) ?? false,
            ollamaName: string(value["ollama_name"]),
            notes: value["notes"] as? [String] ?? []
        )
    }

    private static func string(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    private static func integer(_ value: Any?) -> Int? {
        number(value).map(Int.init)
    }

    private static func boolean(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }
}
