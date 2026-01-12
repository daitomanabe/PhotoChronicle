import AppKit
import Foundation

@MainActor
final class PlannerViewModel: ObservableObject {

    @Published var sources: [SourceItem] = []
    @Published var destFolder: URL? = nil
    @Published var planDBURL: URL? = nil

    @Published var planMode: PlanMode = .new

    @Published var progress: PlannerProgress = PlannerProgress()
    @Published var logs: [String] = []
    @Published var lastError: String? = nil
    @Published var isRunning: Bool = false

    @Published var scanImages: Bool = true
    @Published var scanVideos: Bool = true

    var canStart: Bool {
        !isRunning && !sources.isEmpty && destFolder != nil && (scanImages || scanVideos)
    }

    func bootstrap() {
        // default DB path in Application Support
        if planDBURL == nil {
            planDBURL = defaultPlanDBURL()
        }
    }

    // ... (existing methods until startPhase1) ...

    // MARK: - Phase 1

    func startPhase1() {
        guard !isRunning, let dbURL = planDBURL, let dest = destFolder else {
            log("Error: DB or Dest not set.")
            return
        }

        isRunning = true
        // Clear logs if New
        if planMode == .new {
            logs = []
            progress = PlannerProgress(stage: .idle)
        }

        let currentSources = sources
        let mode = planMode

        // Capture flags for task
        let doImages = scanImages
        let doVideos = scanVideos

        var lastLoggedCount = 0

        Task {
            do {
                let engine = PlannerEngine()  // Instantiate engine inside the task
                try await engine.buildPlan(
                    mode: mode,
                    sources: currentSources,
                    destFolder: dest,
                    dbURL: dbURL,
                    includeImages: doImages,
                    includeVideos: doVideos,
                    progress: { [weak self] p in
                        await MainActor.run {
                            self?.progress = p
                            // Throttle logging: every 1000 items
                            let current = p.discoveredFiles
                            if current - lastLoggedCount >= 1000 {
                                self?.log("Phase 1 Progress: \(current) files scanned...")
                                lastLoggedCount = current
                            }
                        }
                    },
                    log: { [weak self] msg in
                        await MainActor.run { self?.log(msg) }
                    }
                )
                await MainActor.run { [weak self] in
                    self?.isRunning = false

                    if let p = self?.progress {
                        let total = p.hashedFiles  // "Candidates" hashed
                        let unique = p.uniqueBlobs
                        let duplicates = total - unique

                        let msg = """
                            Phase 1 Complete.
                            --------------------------------------------------
                            Total Scanned  : \(p.discoveredFiles)
                            Candidates     : \(total)
                            Unique Files   : \(unique) (To Copy)
                            Duplicates     : \(duplicates) (Skipped)
                            --------------------------------------------------
                            """
                        self?.log(msg)
                    } else {
                        self?.log("Phase 1 Complete.")
                    }
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.isRunning = false
                    self?.lastError = error.localizedDescription
                    self?.log("Error: \(error.localizedDescription)")
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    // MARK: - Phase 2

    // MARK: - Phase 2

    @Published var phase2: Phase2Executor? = nil

    var isRunningPhase2: Bool {
        phase2?.isRunning ?? false
    }

    // MARK: - Logging

    // Debug logging
    private var phase2LogFileURL: URL? = nil

    private func log(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let fullMsg = "[\(ts)] \(msg)"
        logs.append(fullMsg)
        // keep last N lines
        if logs.count > 4000 { logs.removeFirst(logs.count - 4000) }

        // Write to file if enabled
        if let fileURL = phase2LogFileURL {
            if let data = (fullMsg + "\n").data(using: .utf8) {
                // Determine handle or append. For simplicity append directly.
                // Note: MainActor is serial, so this is safe from race conditions within this actor.
                // Performance warning: FileHandle updates on main thread.
                // Given low frequency of logs relative to UI updates, this is acceptable for debug.
                if let handle = try? FileHandle(forWritingTo: fileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    try? handle.close()
                }
            }
        }
    }

    @Published var concurrencyLevel: Int = ProcessInfo.processInfo.activeProcessorCount

    // Update startPhase2 to init log file
    func startPhase2() {
        guard !isRunning, let url = planDBURL else { return }

        // Setup debug log
        if let dest = destFolder {
            let logFile = dest.appendingPathComponent("phase2_execution_log.txt")
            if !FileManager.default.fileExists(atPath: logFile.path) {
                FileManager.default.createFile(atPath: logFile.path, contents: nil)
            }
            self.phase2LogFileURL = logFile
            self.log("Phase 2 Debug Log started at: \(logFile.path)")
        }

        let executor = Phase2Executor(
            dbURL: url,
            log: { [weak self] msg in
                Task { @MainActor in
                    self?.log(msg)
                }
            })
        self.phase2 = executor
        executor.start(concurrency: concurrencyLevel)
    }

    func cancelPhase2() {
        phase2?.cancel()
    }

    func resetPhase2Ops() {
        guard !isRunning, let url = planDBURL else { return }
        do {
            let db = try PlanDB(dbURL: url)
            try db.resetAllOpsToPending()
            self.log("Phase 2 Operations have been reset to PENDING.")

            // Refresh counts
            let pending = try db.pendingOpsCount()
            let total = try db.totalOpsCount()
            self.log("Stats after reset -> Pending: \(pending), Total: \(total)")

            // Update local tracking metrics? They will update on loadPlan or startPhase2

        } catch {
            self.log("Failed to reset ops: \(error.localizedDescription)")
            lastError = error.localizedDescription
        }
    }
}
