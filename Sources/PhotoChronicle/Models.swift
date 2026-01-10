import Foundation

enum PlanMode: String, CaseIterable, Identifiable {
    case new = "New Plan"
    case append = "Append"
    var id: String { rawValue }
}

enum SourceKind: String, Codable {
    case library = "LIBRARY"
    case folder = "FOLDER"
}

struct SourceItem: Identifiable, Hashable, Codable {
    let id: UUID
    let kind: SourceKind
    let url: URL
    let addedAt: Date

    init(kind: SourceKind, url: URL) {
        self.id = UUID()
        self.kind = kind
        self.url = url
        self.addedAt = Date()
    }

    var displayName: String {
        url.lastPathComponent
    }
}

enum PlannerStage: String {
    case idle = "Idle"
    case scanning = "Scanning"
    case hashing = "Hashing"
    case buildingBlobs = "Building blobs"
    case freezing = "Freezing"
    case done = "Done"
    case cancelled = "Cancelled"
    case error = "Error"
}

struct PlannerProgress {
    var stage: PlannerStage = .idle
    var currentPath: String = ""
    var discoveredFiles: Int = 0
    var hashedFiles: Int = 0
    var totalBytesRead: Int64 = 0
    var uniqueBlobs: Int = 0
    var duplicateCount: Int = 0
    var errorCount: Int = 0
}
