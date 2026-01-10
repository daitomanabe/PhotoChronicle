import CryptoKit
import Foundation

enum Phase2Error: Error {
    case planNotFrozen(String)
    case volumeNotMounted(String)
    case srcNotFound(String)
    case srcSizeChanged
    case destExistsMismatch
    case hashMismatch(expected: String, actual: String)
    case ioError(String)
    case cancelled
}

struct Phase2Progress {
    var opsTotal: Int = 0
    var opsDone: Int = 0
    var errorCount: Int = 0
    var bytesCopied: Int64 = 0
    var currentOp: String = ""
}

@MainActor
final class Phase2Executor: ObservableObject {
    @Published var progress = Phase2Progress()
    @Published var isRunning = false
    @Published var lastError: String? = nil

    // Circuit breaker state
    private var consecutiveErrorCount = 0

    // Logging callback
    var logHandler: ((String) -> Void)?
    // We store URL to recreate DB in background task
    private let dbURL: URL
    // Log callback must be Sendable? closures are sendable if capture list is safe.
    // simpler to just call back to main actor
    private let logCallback: (String) -> Void
    private var task: Task<Void, Never>? = nil

    init(dbURL: URL, log: @escaping (String) -> Void) {
        self.dbURL = dbURL
        self.logCallback = log
    }

    // Helper to log safely from background
    nonisolated private func log(_ msg: String) {
        Task { @MainActor in self.logCallback(msg) }
    }

    func start(concurrency: Int = 4) {
        guard !isRunning else { return }
        isRunning = true
        lastError = nil
        progress = Phase2Progress()
        consecutiveErrorCount = 0  // Reset circuit breaker on start

        let url = self.dbURL
        let workers = max(1, min(concurrency, 8))  // Cap at 8

        task = Task.detached(priority: .userInitiated) {
            do {
                try await self.runExecutionLoop(dbURL: url, concurrency: workers)
                await MainActor.run {
                    self.isRunning = false
                    self.logCallback("Phase 2 Complete.")
                    self.progress.currentOp = "All Done."
                }
            } catch {
                await MainActor.run {
                    self.isRunning = false
                    if let p2e = error as? Phase2Error, case .cancelled = p2e {
                        self.logCallback("Phase 2 Cancelled.")
                        self.progress.currentOp = "Cancelled."
                    } else {
                        self.lastError = error.localizedDescription
                        self.logCallback("Phase 2 Error: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    private func writeInterruptionReport(error: String, lastFile: String) async {
        let report = """
            ==================================================
            PHOTO CHRONICLE - INTERRUPTION REPORT
            ==================================================
            Time: \(Date().formatted())

            CRITICAL ERROR:
            \(error)

            LAST ATTEMPTED FILE:
            \(lastFile)

            STATUS:
            - Processed: \(progress.opsDone)
            - Errors: \(progress.errorCount)
            - Remaining: \(progress.opsTotal - progress.opsDone)

            HOW TO RESUME:
            1. Check your connection (NAS/USB Drive).
            2. Restart PhotoChronicle.
            3. Click "Start Phase 2" again.

            The system automatically saved your progress up to the error.
            It will skip all files successfully copied and continue from where it left off.
            ==================================================
            """

        let reportURL = dbURL.deletingLastPathComponent().appendingPathComponent(
            "_INTERRUPTION_REPORT.txt")
        do {
            try report.write(to: reportURL, atomically: true, encoding: String.Encoding.utf8)
            self.log("Report saved to: \(reportURL.path)")
        } catch {
            self.log("Failed to save interruption report: \(error.localizedDescription)")
        }
    }

    // This runs on background thread (detached task)
    nonisolated private func runExecutionLoop(dbURL: URL, concurrency: Int) async throws {
        // Create DB connection specific to this background thread
        log("Phase 2 DB Connection: \(dbURL.path) (Concurrency: \(concurrency))")

        let db = try PlanDB(dbURL: dbURL)

        // Debug: List tables
        let tables = try db.listTables()
        if !tables.contains("ops") {
            log("CRITICAL ERROR: 'ops' table missing! Tables found: \(tables)")
            throw Phase2Error.planNotFrozen("Table 'ops' missing.")
        }

        // 0. Auto-recover stale RUNNING ops
        let recovered = try db.resetStaleRunningOps()
        if recovered > 0 {
            log("Auto-recovered \(recovered) stale 'RUNNING' operations -> 'PENDING'.")
        }

        // 1. Pending count
        let pendingCount = try db.pendingOpsCount()
        let statusCounts = try db.getOpCountsByStatus()
        let statusMsg = statusCounts.map { "\($0.key): \($0.value)" }.joined(separator: ", ")

        await MainActor.run {
            if let total = try? db.totalOpsCount() {
                self.progress.opsTotal = total
                self.progress.opsDone = statusCounts["DONE"] ?? 0
            } else {
                self.progress.opsTotal = pendingCount
            }
        }

        log("Phase 2 Starting. Stats: [\(statusMsg)]")

        // 2. Parallel Loop
        try await withThrowingTaskGroup(of: (Int64, Int64, String?).self) { group in
            var activeTasks = 0

            // Loop until no pending ops left
            while !Task.isCancelled {
                // Check if we need to fetch more ops
                // We fetch a batch equal to free slots
                let freeSlots = concurrency - activeTasks
                if freeSlots > 0 {
                    // Try to reserve batch
                    // We catch error here to avoid breaking loop on DB lock transient issues?
                    // But assume PlanDB retries or we fail hard.
                    let batch = try db.reserveNextOps(limit: freeSlots)

                    if batch.isEmpty && activeTasks == 0 {
                        // Done.
                        break
                    }

                    for op in batch {
                        activeTasks += 1
                        group.addTask {
                            if Task.isCancelled { return (op.0, 0, nil) }
                            do {
                                // Create a separate DB instance? NO.
                                // Passed DB? NO. PlanDB is not thread safe for shared usage.
                                // We MUST NOT use 'db' inside this task if we want concurrency.
                                // Wait, `processOp` uses `db` to read Dest Info.
                                // We need to read Dest Info ONCE outside loop or pass it down.
                                // The Plan Info is constant.
                                // But `processOp` calls `db.readPlanInfo()`.
                                // Refactor: Read Plan Info once per loop? Or create temp DB per task?
                                // Temp DB per task is safest for SQLite concurrency if using separate connections.
                                // OR simpler: Pass the needed info (destUUID, destRoot) to `processOp`.

                                // Let's optimize: We read Plan Info ONCE here.
                                let (destUUID, destRelRoot, _) = try PlanDB(dbURL: dbURL)
                                    .readPlanInfo()  // Use a temp DB to read just once? Or use main `db`.
                                // Main `db` is busy? No, we are in the main loop thread.

                                // Actually, constructing PlanDB is cheap.
                                // Let's create a thread-local PlanDB inside the task?
                                // Yes, that allows true concurrency on WAL mode.

                                let workerDB = try PlanDB(dbURL: dbURL)
                                let bytes = try self.processOp(
                                    op, db: workerDB, destUUID: destUUID, destRelRoot: destRelRoot)
                                return (op.0, bytes, nil)
                            } catch {
                                return (op.0, 0, error.localizedDescription)
                            }
                        }
                    }
                }

                // Wait for one result
                if let result = try await group.next() {
                    activeTasks -= 1
                    let (opID, bytes, errStr) = result

                    if let err = errStr {
                        try db.updateOpStatus(opID: opID, status: "ERROR", error: err)
                        log("Op \(opID) Failed: \(err)")

                        // Circuit breaker check (MainActor)
                        let stop = await MainActor.run {
                            self.consecutiveErrorCount += 1
                            return self.consecutiveErrorCount >= 5
                        }

                        if stop {
                            log(
                                "CRITICAL: Circuit breaker tripped (5 consecutive errors). Stopping."
                            )
                            throw Phase2Error.ioError("Circuit breaker tripped.")
                        }

                    } else {
                        try db.updateOpStatus(
                            opID: opID, status: "DONE", error: nil, bytesCopied: bytes,
                            verified: true)

                        await MainActor.run {
                            self.consecutiveErrorCount = 0  // Reset on success
                            self.progress.opsDone += 1
                            self.progress.bytesCopied += bytes
                        }
                    }
                }
            }
        }

        // Final stats check
        log("Phase 2 Loop Finished.")
    }

    nonisolated private func errorMessage(for error: Error) -> String {
        return error.localizedDescription
    }

    nonisolated private func processOp(
        _ op: (Int64, String, String, String, String, Int64), db: PlanDB,
        destUUID: String?, destRelRoot: String?
    ) throws -> Int64 {
        let (opID, sha256, srcVol, srcRel, destRel, expectedSize) = op

        // 1. Resolve Volumes
        guard let srcRoot = VolumeResolver.mountURL(forVolumeUUID: srcVol) else {
            throw Phase2Error.volumeNotMounted("Src Volume \(srcVol)")
        }

        // Use passed info or fetch if nil (though we expect passed info in optimized loop)
        let dUUID: String
        let dRootRel: String

        if let u = destUUID, let r = destRelRoot {
            dUUID = u
            dRootRel = r
        } else {
            // Fallback for non-optimized calls (if any)
            let (uuid, root, _) = try db.readPlanInfo()
            guard let u = uuid, let r = root else {
                throw Phase2Error.planNotFrozen("Missing dest info in Plan table")
            }
            dUUID = u
            dRootRel = r
        }

        guard let destVolRoot = VolumeResolver.mountURL(forVolumeUUID: dUUID) else {
            throw Phase2Error.volumeNotMounted("Dest Volume \(dUUID)")
        }

        let srcURL = srcRoot.appendingPathComponent(srcRel)
        let destRoot = destVolRoot.appendingPathComponent(dRootRel)
        let destURL = destRoot.appendingPathComponent(destRel)

        // log("Op \(opID) Start: \(srcURL.path) -> \(destURL.path)") // Too verbose for parallel?

        // 2. Verify Src
        let fm = FileManager.default
        guard fm.fileExists(atPath: srcURL.path) else {
            log("Op \(opID) Error: Source not found at \(srcURL.path)")
            throw Phase2Error.srcNotFound(srcURL.path)
        }
        let srcAttr = try fm.attributesOfItem(atPath: srcURL.path)
        let srcSize = srcAttr[.size] as? Int64 ?? 0

        if expectedSize > 0 && srcSize != expectedSize {
            log("Op \(opID) Error: Source size mismatch. Expected \(expectedSize), got \(srcSize)")
            throw Phase2Error.srcSizeChanged
        }

        // 3. Check Dest Idempotency
        if fm.fileExists(atPath: destURL.path) {
            let destAttr = try fm.attributesOfItem(atPath: destURL.path)
            let destSize = destAttr[.size] as? Int64 ?? 0

            if destSize == expectedSize {
                log("Op \(opID) Skipped: Destination exists and matches size.")
                return 0
            } else {
                log("Op \(opID) Error: Dest exists mismatch.")
                throw Phase2Error.destExistsMismatch
            }
        }

        // 4. Atomic Copy
        let destDir = destURL.deletingLastPathComponent()
        if !fm.fileExists(atPath: destDir.path) {
            try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
            // log("Op \(opID) Created Dir: \(destDir.path)") // verbose
        }

        let tmpURL = destDir.appendingPathComponent(".\(sha256).tmp")
        if fm.fileExists(atPath: tmpURL.path) {
            try fm.removeItem(at: tmpURL)
        }

        let (computedHash, bytesWritten) = try copyAndHash(from: srcURL, to: tmpURL)

        // 5. Verify Hash
        if computedHash != sha256 {
            try? fm.removeItem(at: tmpURL)
            log("Op \(opID) Hash Mismatch! Expected \(sha256), got \(computedHash)")
            throw Phase2Error.hashMismatch(expected: sha256, actual: computedHash)
        }

        // 6. Rename
        try fm.moveItem(at: tmpURL, to: destURL)
        log("Op \(opID) Success: Copied & Verified.")

        // 7. Preserve Metadata (Timestamps)
        do {
            let srcAttrs = try fm.attributesOfItem(atPath: srcURL.path)
            var destAttrs: [FileAttributeKey: Any] = [:]

            if let creationDate = srcAttrs[.creationDate] {
                destAttrs[.creationDate] = creationDate
            }
            if let modificationDate = srcAttrs[.modificationDate] {
                destAttrs[.modificationDate] = modificationDate
            }

            if !destAttrs.isEmpty {
                try fm.setAttributes(destAttrs, ofItemAtPath: destURL.path)
            }
        } catch {
            log("Op \(opID) Warning: Failed to copy attributes: \(error.localizedDescription)")
        }

        return bytesWritten
    }

    nonisolated private func copyAndHash(from src: URL, to dest: URL) throws -> (String, Int64) {
        // Create file using FileManager first to ensure existence? No, streams.
        // Or create empty file.
        FileManager.default.createFile(atPath: dest.path, contents: nil)

        let readHandle = try FileHandle(forReadingFrom: src)
        let writeHandle = try FileHandle(forWritingTo: dest)
        defer {
            try? readHandle.close()
            try? writeHandle.close()
        }

        var hasher = SHA256()
        var total: Int64 = 0
        let chunkSize = 4 * 1024 * 1024  // 4MB

        while true {
            if Task.isCancelled { throw Phase2Error.cancelled }
            guard let data = try readHandle.read(upToCount: chunkSize), !data.isEmpty else {
                break
            }
            try writeHandle.write(contentsOf: data)
            hasher.update(data: data)
            total += Int64(data.count)
        }

        let digest = hasher.finalize()
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return (hex, total)
    }
}
