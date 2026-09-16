import Darwin
import Foundation

enum StorageScannerError: LocalizedError {
    case notDirectory(String)
    case cannotEnumerate(String)
    case memoryLimitReached

    var errorDescription: String? {
        switch self {
        case .notDirectory(let path): "The selected storage root is not a readable directory: \(path)"
        case .cannotEnumerate(let path): "Topps could not enumerate the selected directory: \(path)"
        case .memoryLimitReached: "The scan stopped before Topps reached its memory safety limit. Choose a more focused folder or relaunch Topps before scanning again."
        }
    }
}

private let storageScanCancellationCallback: @convention(c) () -> Int32 = {
    if withUnsafeCurrentTask(body: { $0?.isCancelled ?? false }) { return 1 }
    var process = CPSProcessInfo()
    guard cps_read_process(getpid(), &process) == 1 else { return 0 }
    let footprint = process.physical_footprint > 0 ? process.physical_footprint : process.resident_bytes
    return footprint >= 700_000_000 ? 2 : 0
}

enum StorageScanner {
    static let largeFileThreshold: UInt64 = 100_000_000
    private static let entryCapacity = 1_400

    static func scan(root: URL, capturedAt: Date = Date()) async throws -> StorageSnapshot {
        let standardizedRoot = root.standardizedFileURL
        let worker = Task.detached(priority: .utility) {
            try scanSynchronously(root: standardizedRoot, capturedAt: capturedAt)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func scanSynchronously(root: URL, capturedAt: Date) throws -> StorageSnapshot {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw StorageScannerError.notDirectory(root.path)
        }

        let startedAt = Date()
        var summary = CPSStorageSummary()
        var rawEntries = [CPSStorageEntry](repeating: CPSStorageEntry(), count: entryCapacity)
        let count = root.path.withCString { rootPath in
            rawEntries.withUnsafeMutableBufferPointer { entries in
                cps_scan_storage(rootPath, entries.baseAddress, Int32(entries.count), &summary, storageScanCancellationCallback)
            }
        }
        try Task.checkCancellation()
        if summary.cancellation_reason == 1 { throw CancellationError() }
        if summary.cancellation_reason == 2 { throw StorageScannerError.memoryLimitReached }
        guard count >= 0 else {
            if summary.error_code == ENOTDIR { throw StorageScannerError.notDirectory(root.path) }
            throw StorageScannerError.cannotEnumerate(root.path)
        }

        var retained: [String: StorageEntry] = [:]
        retained.reserveCapacity(Int(count))
        for var raw in rawEntries.prefix(Int(count)) {
            let path = cString(&raw.path)
            guard !path.isEmpty else { continue }
            let kind: StorageItemKind = raw.is_directory == 1 ? .directory : .file
            retained[path] = StorageEntry(
                path: path,
                kind: kind,
                category: StorageAnalysis.category(for: path, kind: kind),
                allocatedBytes: raw.allocated_bytes,
                logicalBytes: raw.logical_bytes,
                fileCount: raw.file_count,
                modifiedAt: raw.modified_seconds > 0 ? Date(timeIntervalSince1970: TimeInterval(raw.modified_seconds)) : nil
            )
        }
        let entries = retained.values.sorted { $0.allocatedBytes > $1.allocatedBytes }

        return StorageSnapshot(
            id: UUID(),
            rootPath: root.path,
            capturedAt: capturedAt,
            allocatedBytes: summary.allocated_bytes,
            logicalBytes: summary.logical_bytes,
            fileCount: summary.file_count,
            unreadableItemCount: summary.unreadable_item_count,
            duration: Date().timeIntervalSince(startedAt),
            entries: entries
        )
    }

    private static func cString<T>(_ tuple: inout T) -> String {
        withUnsafePointer(to: &tuple) {
            $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                String(cString: $0)
            }
        }
    }
}

actor StorageHistoryStore {
    private let fileURL: URL
    private var cachedSnapshots: [StorageSnapshot]?

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            self.fileURL = base.appendingPathComponent("Topps/storage-history.json")
        }
    }

    func snapshots() -> [StorageSnapshot] {
        if let cachedSnapshots { return cachedSnapshots }
        guard let data = try? Data(contentsOf: fileURL) else {
            cachedSnapshots = []
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let values = (try? decoder.decode([StorageSnapshot].self, from: data)) ?? []
        cachedSnapshots = values.sorted { $0.capturedAt > $1.capturedAt }
        return cachedSnapshots ?? []
    }

    func record(_ snapshot: StorageSnapshot) throws -> [StorageSnapshot] {
        var values = snapshots()
        values.removeAll { $0.id == snapshot.id }
        values.append(snapshot)
        values.sort { $0.capturedAt > $1.capturedAt }

        var counts: [String: Int] = [:]
        values = values.filter { value in
            let count = counts[value.rootPath, default: 0]
            guard count < 24 else { return false }
            counts[value.rootPath] = count + 1
            return true
        }
        if values.count > 120 { values.removeLast(values.count - 120) }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(values)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        cachedSnapshots = values
        return values
    }
}

enum StorageAnalysis {
    static func findings(current: StorageSnapshot, previous: StorageSnapshot?) -> [StorageFinding] {
        let previousByPath = Dictionary(uniqueKeysWithValues: (previous?.entries ?? []).map { ($0.path, $0.allocatedBytes) })
        return current.entries.map { entry in
            let recommendation = recommendation(for: entry)
            return StorageFinding(
                entry: entry,
                previousBytes: previousByPath[entry.path],
                recommendation: recommendation.kind,
                recommendationReason: recommendation.reason
            )
        }
    }

    static func rootGrowth(current: StorageSnapshot, previous: StorageSnapshot?) -> Int64? {
        guard let previous else { return nil }
        if current.allocatedBytes >= previous.allocatedBytes { return Int64(clamping: current.allocatedBytes - previous.allocatedBytes) }
        return -Int64(clamping: previous.allocatedBytes - current.allocatedBytes)
    }

    static func category(for path: String, kind: StorageItemKind) -> StorageCategory {
        let components = URL(fileURLWithPath: path).pathComponents.map { $0.lowercased() }
        let name = components.last ?? ""
        let cacheNames: Set<String> = ["cache", "caches", ".cache", ".npm", ".yarn", ".pnpm-store"]
        let dependencyNames: Set<String> = ["node_modules", "vendor", "pods", ".venv", "venv", ".gradle"]
        let buildNames: Set<String> = ["build", ".build", "target", "deriveddata", "dist", ".next", ".nuxt", "out", "coverage"]

        if components.contains(where: cacheNames.contains) { return .cache }
        if components.contains(".cargo"), components.contains(where: { $0 == "registry" || $0 == "git" }) { return .cache }
        if components.contains(where: dependencyNames.contains) { return .dependencies }
        if components.contains(where: buildNames.contains) { return .buildArtifacts }
        if components.contains("downloads") { return .downloads }
        if path.lowercased().contains("/library/application support/") { return .applicationData }
        if kind == .file { return .largeFile }
        if cacheNames.contains(name) { return .cache }
        return .other
    }

    private static func recommendation(for entry: StorageEntry) -> (kind: StorageRecommendationKind, reason: String) {
        switch entry.category {
        case .cache:
            return (.reviewDelete, "Caches are often recreated, but quit the owning app and inspect the contents before removing them.")
        case .dependencies:
            return (.reviewDelete, "Dependencies such as node_modules or virtual environments can usually be restored from their lockfiles.")
        case .buildArtifacts:
            return (.reviewDelete, "Build output is usually reproducible from source. Confirm no unique artifacts are stored here.")
        case .applicationData:
            return (.inspect, "Application Support may contain irreplaceable state. Use the owning application's storage controls when possible.")
        case .downloads:
            if entry.allocatedBytes >= 1_000_000_000 {
                return (.cloudArchive, "Older downloads and installers are often suitable for archival after verifying they are no longer active.")
            }
            return (.inspect, "Review whether these downloads are still needed.")
        case .largeFile:
            let ext = URL(fileURLWithPath: entry.path).pathExtension.lowercased()
            let archiveExtensions: Set<String> = ["zip", "7z", "rar", "tar", "gz", "dmg", "iso", "pkg"]
            let externalExtensions: Set<String> = ["gguf", "safetensors", "onnx", "mov", "mp4", "mkv", "parquet"]
            if archiveExtensions.contains(ext) {
                return (.cloudArchive, "This large archive or installer may not need to remain on fast local storage.")
            }
            if externalExtensions.contains(ext), entry.allocatedBytes >= 1_000_000_000 {
                return (.externalStorage, "Large media, model, or dataset files can often live on a fast external SSD when not latency-critical.")
            }
            return (.inspect, "This is one of the largest individual files in the scanned root.")
        case .other:
            let lowerName = entry.name.lowercased()
            let moveNames = ["models", "datasets", "archives", "archive", "backups", "media", "videos"]
            if entry.allocatedBytes >= 5_000_000_000, moveNames.contains(where: lowerName.contains) {
                return (.externalStorage, "This large collection appears suitable for external storage if it is not needed continuously.")
            }
            return (.inspect, "Large folders deserve review, but Topps cannot safely infer whether their contents are disposable.")
        }
    }
}
