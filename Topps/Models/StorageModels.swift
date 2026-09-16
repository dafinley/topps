import Foundation

enum StorageItemKind: String, Codable, Sendable {
    case directory
    case file
}

enum StorageCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case cache
    case dependencies
    case buildArtifacts
    case downloads
    case applicationData
    case largeFile
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cache: "Cache"
        case .dependencies: "Dependencies"
        case .buildArtifacts: "Build Output"
        case .downloads: "Downloads"
        case .applicationData: "App Data"
        case .largeFile: "Large File"
        case .other: "Other"
        }
    }

    var icon: String {
        switch self {
        case .cache: "clock.arrow.circlepath"
        case .dependencies: "shippingbox"
        case .buildArtifacts: "hammer"
        case .downloads: "arrow.down.circle"
        case .applicationData: "app.badge"
        case .largeFile: "doc.fill"
        case .other: "folder.fill"
        }
    }
}

enum StorageRecommendationKind: String, Codable, Sendable {
    case reviewDelete
    case externalStorage
    case cloudArchive
    case inspect

    var label: String {
        switch self {
        case .reviewDelete: "Review for deletion"
        case .externalStorage: "External SSD candidate"
        case .cloudArchive: "Cloud/archive candidate"
        case .inspect: "Inspect"
        }
    }

    var icon: String {
        switch self {
        case .reviewDelete: "trash.slash"
        case .externalStorage: "externaldrive"
        case .cloudArchive: "icloud.and.arrow.up"
        case .inspect: "magnifyingglass"
        }
    }
}

struct StorageEntry: Identifiable, Codable, Hashable, Sendable {
    let path: String
    let kind: StorageItemKind
    let category: StorageCategory
    let allocatedBytes: UInt64
    let logicalBytes: UInt64
    let fileCount: UInt64
    let modifiedAt: Date?

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct StorageSnapshot: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let rootPath: String
    let capturedAt: Date
    let allocatedBytes: UInt64
    let logicalBytes: UInt64
    let fileCount: UInt64
    let unreadableItemCount: UInt64
    let duration: TimeInterval
    let entries: [StorageEntry]

    var rootName: String {
        let url = URL(fileURLWithPath: rootPath)
        return rootPath == FileManager.default.homeDirectoryForCurrentUser.path ? "Home" : url.lastPathComponent
    }
}

struct StorageFinding: Identifiable, Hashable, Sendable {
    let entry: StorageEntry
    let previousBytes: UInt64?
    let recommendation: StorageRecommendationKind
    let recommendationReason: String

    var id: String { entry.path }

    var growth: Int64? {
        guard let previousBytes else { return nil }
        if entry.allocatedBytes >= previousBytes { return Int64(clamping: entry.allocatedBytes - previousBytes) }
        return -Int64(clamping: previousBytes - entry.allocatedBytes)
    }
}

enum StorageViewMode: String, CaseIterable, Identifiable, Sendable {
    case growth = "Growth"
    case cleanup = "Cleanup"
    case move = "Move / Archive"
    case largest = "Largest"

    var id: String { rawValue }
}
