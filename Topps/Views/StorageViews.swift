import SwiftUI

private struct StorageQuickRoot {
    let label: String
    let path: String
}

struct StorageGrowthView: View {
    @EnvironmentObject private var store: ToppsStore

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = store.storageScanError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color.red.opacity(0.08))
            }
            if let snapshot = store.latestStorageSnapshot {
                snapshotContent(snapshot)
            } else if store.isScanningStorage {
                scanningPlaceholder
            } else {
                emptyState
            }
        }
        .task { store.loadStorageHistory() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Storage Growth").font(.title2.weight(.semibold))
                    Text("Track where disk space accumulates and identify safe places to investigate.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(quickRoots, id: \.path) { root in
                        Button(root.label) {
                            store.setStorageRoot(URL(fileURLWithPath: root.path, isDirectory: true))
                            store.scanSelectedStorageRoot()
                        }
                    }
                    Divider()
                    Button("Choose Another Folder…") { store.chooseStorageRoot() }
                } label: {
                    Label("Common Locations", systemImage: "folder")
                }
                .disabled(store.isScanningStorage)
                Button("Choose Folder…") { store.chooseStorageRoot() }
                    .disabled(store.isScanningStorage)
                if store.isScanningStorage {
                    Button("Cancel", role: .cancel) { store.cancelStorageScan() }
                } else {
                    Button { store.scanSelectedStorageRoot() } label: {
                        Label(store.latestStorageSnapshot == nil ? "Capture Baseline" : "Scan Again", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            HStack(spacing: 7) {
                Image(systemName: "folder.fill").foregroundStyle(.secondary)
                Text(store.selectedStorageRootPath)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                if store.isScanningStorage {
                    ProgressView().controlSize(.small)
                    Text("Scanning on demand…").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }

    private func snapshotContent(_ snapshot: StorageSnapshot) -> some View {
        VStack(spacing: 0) {
            summary(snapshot)
            Divider()
            HStack {
                Picker("View", selection: $store.storageViewMode) {
                    ForEach(StorageViewMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 500)
                Spacer()
                Text("Folder sizes overlap; do not add rows together.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            if store.storageFindings.isEmpty {
                ContentUnavailableView {
                    Label(emptyModeTitle, systemImage: emptyModeIcon)
                } description: {
                    Text(emptyModeDescription)
                } actions: {
                    if !store.isScanningStorage {
                        Button("Scan Again") { store.scanSelectedStorageRoot() }
                    }
                }
            } else {
                List(selection: $store.selectedStorageFindingPath) {
                    ForEach(store.storageFindings) { finding in
                        findingRow(finding)
                            .tag(finding.entry.path)
                            .contextMenu {
                                Button("Reveal in Finder") { store.revealStorageItem(finding.entry.path) }
                                Button("Copy Path") { store.copy(finding.entry.path) }
                            }
                    }
                }
                .listStyle(.inset)
            }

            HStack {
                Text("Snapshot: \(snapshot.capturedAt.formatted(date: .abbreviated, time: .standard))")
                Text("· \(snapshot.fileCount.formatted()) files")
                Text("· \(snapshot.duration.formatted(.number.precision(.fractionLength(1))))s")
                if snapshot.unreadableItemCount > 0 { Text("· \(snapshot.unreadableItemCount) unreadable") }
                Spacer()
                Text("Recommendations are review prompts—Topps never deletes or moves files.")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.bar)
        }
    }

    private func summary(_ snapshot: StorageSnapshot) -> some View {
        let findings = StorageAnalysis.findings(current: snapshot, previous: store.previousStorageSnapshot)
        let cleanup = findings.filter { $0.recommendation == .reviewDelete }.max { $0.entry.allocatedBytes < $1.entry.allocatedBytes }
        let move = findings.filter { $0.recommendation == .externalStorage || $0.recommendation == .cloudArchive }.max { $0.entry.allocatedBytes < $1.entry.allocatedBytes }
        let growth = StorageAnalysis.rootGrowth(current: snapshot, previous: store.previousStorageSnapshot)
        return VStack(spacing: 9) {
            HStack(spacing: 8) {
                MetricCard(title: "Scanned Size", value: ByteFormat.string(snapshot.allocatedBytes), detail: "allocated on disk", color: .blue)
                MetricCard(title: "Root Change", value: growth.map(ByteFormat.signed) ?? "Baseline", detail: store.previousStorageSnapshot == nil ? "scan again later to compare" : "since previous scan", color: growthColor(growth))
                MetricCard(title: "Cleanup Lead", value: cleanup.map { ByteFormat.string($0.entry.allocatedBytes) } ?? "None", detail: cleanup?.entry.name ?? "no reproducible artifact found", color: .orange)
                MetricCard(title: "Move Lead", value: move.map { ByteFormat.string($0.entry.allocatedBytes) } ?? "None", detail: move?.entry.name ?? "no strong candidate found", color: .purple)
            }
            if store.selectedStorageSnapshots.count > 1 {
                HStack(spacing: 10) {
                    Text("ROOT SIZE HISTORY").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Sparkline(values: store.selectedStorageSnapshots.reversed().map { Double($0.allocatedBytes) }, color: .blue)
                        .frame(height: 30)
                    Text("\(store.selectedStorageSnapshots.count) snapshots")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
    }

    private func findingRow(_ finding: StorageFinding) -> some View {
        HStack(spacing: 10) {
            Image(systemName: finding.entry.category.icon)
                .foregroundStyle(categoryColor(finding.entry.category))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(finding.entry.name).fontWeight(.medium).lineLimit(1)
                    categoryBadge(finding.entry.category)
                }
                Text(finding.entry.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(ByteFormat.string(finding.entry.allocatedBytes)).monospacedDigit().fontWeight(.medium)
                Text(finding.entry.kind == .directory ? "\(finding.entry.fileCount.formatted()) files" : "large file")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 90, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 2) {
                Text(finding.growth.map(ByteFormat.signed) ?? "No baseline")
                    .monospacedDigit()
                    .foregroundStyle(growthColor(finding.growth))
                Text("since prior scan").font(.caption2).foregroundStyle(.secondary)
            }
            .frame(width: 105, alignment: .trailing)
            Label(finding.recommendation.label, systemImage: finding.recommendation.icon)
                .font(.caption2.weight(.medium))
                .foregroundStyle(recommendationColor(finding.recommendation))
                .frame(width: 145, alignment: .leading)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var scanningPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Streaming files and measuring allocated disk space…").font(.headline)
            Text("Large roots can take several minutes. Results are kept in a fixed memory budget, stay on this Mac, and can be cancelled safely.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Cancel Scan", role: .cancel) { store.cancelStorageScan() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Capture a Storage Baseline", systemImage: "internaldrive")
        } description: {
            Text("Choose a focused folder for a fast scan, or scan Home to establish a broad baseline. A later scan reveals which exact paths grew.")
        } actions: {
            Button("Capture Home Baseline") {
                store.setStorageRoot(FileManager.default.homeDirectoryForCurrentUser)
                store.scanSelectedStorageRoot()
            }
            .buttonStyle(.borderedProminent)
            Button("Choose Folder…") { store.chooseStorageRoot() }
        }
    }

    private var quickRoots: [StorageQuickRoot] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            StorageQuickRoot(label: "Home", path: home.path),
            StorageQuickRoot(label: "User Caches", path: home.appendingPathComponent("Library/Caches").path),
            StorageQuickRoot(label: "Developer Data", path: home.appendingPathComponent("Library/Developer").path),
            StorageQuickRoot(label: "Downloads", path: home.appendingPathComponent("Downloads").path),
            StorageQuickRoot(label: "Development Projects", path: home.appendingPathComponent("dev").path)
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private var emptyModeTitle: String {
        switch store.storageViewMode {
        case .growth: store.previousStorageSnapshot == nil ? "Baseline Captured" : "No Tracked Growth"
        case .cleanup: "No Cleanup Candidates"
        case .move: "No Move Candidates"
        case .largest: "No Large Items Found"
        }
    }

    private var emptyModeIcon: String {
        switch store.storageViewMode {
        case .growth: "chart.line.uptrend.xyaxis"
        case .cleanup: "checkmark.circle"
        case .move: "externaldrive"
        case .largest: "folder"
        }
    }

    private var emptyModeDescription: String {
        switch store.storageViewMode {
        case .growth:
            store.previousStorageSnapshot == nil
                ? "This first scan is the baseline. Scan the same root again later to see which tracked files and folders grew."
                : "No retained paths grew between the two latest snapshots."
        case .cleanup: "Topps did not find a known cache, dependency, or reproducible build folder in the retained results."
        case .move: "Topps did not find a strong external SSD or cloud archive candidate."
        case .largest: "The selected root contained no measurable regular files."
        }
    }

    private func categoryBadge(_ category: StorageCategory) -> some View {
        Text(category.label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(categoryColor(category))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(categoryColor(category).opacity(0.1), in: Capsule())
    }

    private func categoryColor(_ category: StorageCategory) -> Color {
        switch category {
        case .cache: .orange
        case .dependencies: .mint
        case .buildArtifacts: .yellow
        case .downloads: .blue
        case .applicationData: .indigo
        case .largeFile: .purple
        case .other: .secondary
        }
    }

    private func recommendationColor(_ recommendation: StorageRecommendationKind) -> Color {
        switch recommendation {
        case .reviewDelete: .orange
        case .externalStorage: .purple
        case .cloudArchive: .blue
        case .inspect: .secondary
        }
    }

    private func growthColor(_ growth: Int64?) -> Color {
        guard let growth else { return .secondary }
        if growth > 0 { return .orange }
        if growth < 0 { return .green }
        return .secondary
    }
}

struct StorageInspectorView: View {
    @EnvironmentObject private var store: ToppsStore

    var body: some View {
        ScrollView {
            if let finding = store.selectedStorageFinding {
                findingInspector(finding)
            } else {
                guide
            }
        }
        .padding(12)
    }

    private func findingInspector(_ finding: StorageFinding) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Image(systemName: finding.entry.category.icon).font(.largeTitle).foregroundStyle(.blue)
                Text(finding.entry.name).font(.title3.weight(.semibold)).textSelection(.enabled)
                Text(finding.entry.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Button("Reveal in Finder") { store.revealStorageItem(finding.entry.path) }
                Button("Copy Path") { store.copy(finding.entry.path) }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("MEASURED").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                KeyValueRow(key: "Allocated", value: ByteFormat.string(finding.entry.allocatedBytes))
                KeyValueRow(key: "Logical", value: ByteFormat.string(finding.entry.logicalBytes))
                KeyValueRow(key: "Previous", value: finding.previousBytes.map { ByteFormat.string($0) } ?? "No baseline")
                KeyValueRow(key: "Growth", value: finding.growth.map(ByteFormat.signed) ?? "No baseline")
                KeyValueRow(key: "Contents", value: finding.entry.kind == .directory ? "\(finding.entry.fileCount.formatted()) files" : "File")
                if let modifiedAt = finding.entry.modifiedAt {
                    KeyValueRow(key: "Last change", value: modifiedAt.formatted(date: .abbreviated, time: .shortened))
                }
            }
            .inspectorSection()
            VStack(alignment: .leading, spacing: 7) {
                Label(finding.recommendation.label, systemImage: finding.recommendation.icon).font(.headline)
                Text(finding.recommendationReason).font(.caption).foregroundStyle(.secondary)
            }
            .inspectorSection()
            safetyNotice
        }
    }

    private var guide: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Storage Growth", systemImage: "internaldrive").font(.title3.weight(.semibold))
            Text("Select a result to see its measured size, change from the prior snapshot, and why Topps surfaced it.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Label("Growth", systemImage: "chart.line.uptrend.xyaxis")
                Text("Compares exact paths between the two latest scans of the same root.").font(.caption).foregroundStyle(.secondary)
                Divider()
                Label("Cleanup", systemImage: "trash.slash")
                Text("Highlights reproducible caches, dependencies, and build output for review.").font(.caption).foregroundStyle(.secondary)
                Divider()
                Label("Move / Archive", systemImage: "externaldrive")
                Text("Surfaces large archives, media, models, datasets, and backups that may not need fast internal storage.").font(.caption).foregroundStyle(.secondary)
            }
            .inspectorSection()
            safetyNotice
        }
    }

    private var safetyNotice: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Review before changing anything", systemImage: "exclamationmark.shield")
                .font(.caption.weight(.semibold))
            Text("Topps only measures and recommends. It never deletes or moves files. Quit owning applications, confirm backups, and prefer application-provided cleanup tools.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }
}
