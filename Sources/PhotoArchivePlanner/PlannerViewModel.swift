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

    private var task: Task<Void, Never>? = nil

    var canStart: Bool {
        !isRunning && !sources.isEmpty && destFolder != nil
    }

    func bootstrap() {
        // default DB path in Application Support
        if planDBURL == nil {
            planDBURL = defaultPlanDBURL()
        }
    }

    func defaultPlanDBURL() -> URL {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("PhotoArchivePlanner", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let ts = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(
            of: ":", with: "-")
        return dir.appendingPathComponent("plan-\(ts).sqlite")
    }

    // MARK: - Source management

    func addSources(from urls: [URL]) {
        guard !isRunning else { return }
        lastError = nil

        for url in urls {
            let resolved = url.resolvingSymlinksInPath()
            guard FileManager.default.fileExists(atPath: resolved.path) else { continue }

            if isLibraryURL(resolved) {
                addSource(kind: .library, url: resolved)
            } else if resolved.hasDirectoryPath {
                addSource(kind: .folder, url: resolved)
            } else {
                // ignore file drops for now (can be extended)
                log("Ignored non-folder: \(resolved.path)")
            }
        }
    }

    private func addSource(kind: SourceKind, url: URL) {
        if sources.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            return
        }
        sources.append(SourceItem(kind: kind, url: url))
        log("Added \(kind.rawValue): \(url.path)")
    }

    func removeSource(_ s: SourceItem) {
        guard !isRunning else { return }
        sources.removeAll { $0.id == s.id }
    }

    func clearSources() {
        guard !isRunning else { return }
        sources.removeAll()
    }

    private func isLibraryURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "photoslibrary" || ext == "photolibrary"
    }

    // MARK: - Destination

    func setDestinationFromDrop(_ urls: [URL]) {
        guard !isRunning else { return }
        guard let first = urls.first else { return }
        let resolved = first.resolvingSymlinksInPath()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir),
            isDir.boolValue
        else {
            lastError = "Destination must be a folder."
            return
        }
        destFolder = resolved
        log("Set DEST: \(resolved.path)")
    }

    func openChooseDestPanel() {
        guard !isRunning else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        p.prompt = "Choose"
        p.begin { resp in
            guard resp == .OK, let url = p.url else { return }
            self.destFolder = url
            self.log("Set DEST: \(url.path)")
        }
    }

    func openAddSourcesPanel() {
        guard !isRunning else { return }
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = true
        p.allowsMultipleSelection = true
        p.prompt = "Add"
        p.begin { resp in
            guard resp == .OK else { return }
            self.addSources(from: p.urls)
        }
    }

    func openChooseDBPanel(merging: Bool = false) {
        guard !isRunning else { return }

        if planMode == .new && !merging {
            let p = NSSavePanel()
            p.allowedContentTypes = []
            p.nameFieldStringValue = planDBURL?.lastPathComponent ?? "plan.sqlite"
            p.prompt = "Create"
            p.message = "Create a new plan database (will overwrite if exists)."
            p.begin { resp in
                guard resp == .OK, let url = p.url else { return }
                self.planDBURL = url
                self.log("Set Plan DB (New): \(url.path)")
                self.resetProgress()
            }
        } else {
            let p = NSOpenPanel()
            p.allowedContentTypes = []
            p.canChooseFiles = true
            p.canChooseDirectories = false
            p.allowsMultipleSelection = false
            p.prompt = merging ? "Append" : "Select"
            p.message =
                merging
                ? "Select a plan.sqlite to merge operations from." : "Select a plan.sqlite to load."

            p.begin { resp in
                guard resp == .OK, let url = p.url else { return }

                if merging {
                    self.loadOrMergePlan(url: url)
                } else {
                    // Force replace
                    self.planDBURL = url
                    self.log("Set Plan DB (Load): \(url.path)")
                    if FileManager.default.fileExists(atPath: url.path) {
                        self.loadPlan()
                    }
                }
            }
        }
    }

    func resetProgress() {
        self.progress = PlannerProgress(stage: .idle)
    }

    func loadOrMergePlan(url: URL) {
        if let currentURL = planDBURL {
            // MERGE
            self.log("Attempting to MERGE ops from: \(url.path)")
            do {
                let db = try PlanDB(dbURL: currentURL)
                let count = try db.mergeOpsFrom(otherDBPath: url.path)
                self.log("Successfully merged \(count) pending ops from secondary plan.")

                // Refresh metrics
                self.progress.hashedFiles += 0  // or track newly added?
                // we should re-query pending ops count ideally
                let pending = try db.pendingOpsCount()
                self.log("Total Pending Ops after merge: \(pending)")

            } catch {
                self.log("Failed to merge plan: \(error.localizedDescription)")
            }
        } else {
            // LOAD
            self.planDBURL = url
            self.log("Set Plan DB (Load): \(url.path)")
            if FileManager.default.fileExists(atPath: url.path) {
                self.loadPlan()
            }
        }
    }

    func loadPlan() {
        guard let url = planDBURL else { return }
        do {
            let db = try PlanDB(dbURL: url)  // will apply schema if needed

            // Load dest
            let (uuid, root, state) = try db.readPlanInfo()
            if let uuid = uuid {
                if let r = VolumeResolver.mountURL(forVolumeUUID: uuid) {
                    let dest = r.appendingPathComponent(root ?? "")
                    self.destFolder = dest
                    self.log("Loaded DEST from plan: \(dest.path) (State: \(state ?? "N/A"))")
                } else {
                    self.log("WARN: Plan destination volume (UUID=\(uuid)) is not mounted.")
                }
            }

            // If FROZEN, ensure we are in a state that allows Phase 2?
            // For now just logging. The UI checks phase2 presence or just button availability.
            if state == "FROZEN" {
                // Potentially auto-switch tab or enable Phase 2 button
            }

            // Load sources
            let loadedSources = try db.readSources()
            var count = 0
            for (kindStr, path) in loadedSources {
                let u = URL(fileURLWithPath: path)
                if !sources.contains(where: { $0.url.path == u.path }) {
                    let k: SourceKind = (kindStr == "LIBRARY") ? .library : .folder
                    sources.append(SourceItem(kind: k, url: u))
                    count += 1
                }
            }
            if count > 0 {
                self.log("Loaded \(count) sources from plan.")
            }

            // Update metrics
            let stats = try db.readStats()
            self.progress.hashedFiles = stats.hashed
            self.progress.uniqueBlobs = stats.unique
            self.progress.duplicateCount = stats.hashed - stats.unique  // approx

            // CHECK & REPAIR: Ensure ops table exists
            let totalOps = try db.totalOpsCount()
            if stats.unique > 0 && totalOps == 0 {
                self.log("WARN: Operations table missing or empty. Repairing plan...")
                try db.buildOpsTable()
                self.log("Plan repaired. Operations generated.")
            } else if totalOps > 0 {
                let pending = try db.pendingOpsCount()
                if pending == 0 {
                    self.log("NOTE: Plan appears fully executed (0 pending ops).")
                }
            }

        } catch {
            self.log("Failed to load plan: \(error.localizedDescription)")
        }
    }

    func revealPlanDBInFinder() {
        guard let url = planDBURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

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

        Task {
            do {
                let engine = PlannerEngine()  // Instantiate engine inside the task
                try await engine.buildPlan(
                    mode: mode,
                    sources: currentSources,
                    destFolder: dest,
                    dbURL: dbURL,
                    progress: { [weak self] p in
                        await MainActor.run { self?.progress = p }
                    },
                    log: { [weak self] msg in
                        await MainActor.run { self?.log(msg) }
                    }
                )
                await MainActor.run { [weak self] in
                    self?.isRunning = false
                    self?.log("Phase 1 Complete.")
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
        executor.start()
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
