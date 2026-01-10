import Foundation

/// Phase 1 planner engine:
/// - scan sources
/// - hash candidates
/// - build blobs (canonical only) + EXIF->date (fallback mtime UTC)
/// - build ops (COPY only)
/// - freeze plan
///
/// NOTE: This is a pragmatic implementation for a first working version.
/// For multi-million files, you will likely want more batching, parallel hashing,
/// and more sophisticated filtering (and perhaps lower-level directory enumeration).
struct PlannerEngine {

    // Candidate extensions (images only)
    private let imageExts: Set<String> = [
        "jpg","jpeg","heic","heif","png","tif","tiff","gif","bmp","webp",
        "dng","cr2","cr3","nef","arw","raf","orf","rw2"
    ]

    struct ScanResult: Sendable {
        let fileURL: URL
        let relPath: String
        let volumeUUID: String
        let size: Int64
        let mtime: Int64
        let sid: Int64
        let sha256: String
        let bytesRead: Int64
    }

    func buildPlan(
        mode: PlanMode,
        sources: [SourceItem],
        destFolder: URL,
        dbURL: URL,
        progress: @escaping @Sendable (PlannerProgress) async -> Void,
        log: @escaping @Sendable (String) async -> Void
    ) async throws {

        var prog = PlannerProgress(stage: .scanning)
        
        // If append, load existing stats for progress baseline?
        // Actually the view model loads it. Here we might start with 0 processed in this run.
        // But let's just emit initial state.
        
        await progress(prog)

        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let db = try PlanDB(dbURL: dbURL)
        
        if mode == .new {
            await log("Mode: NEW. Resetting DB...")
            try db.dropAllTables()
        } else {
            await log("Mode: APPEND. Unfreezing plan...")
        }

        try db.applySchema()
        if mode == .append {
            try db.unfreezePlan()
        }

        // DEST info
        guard let destVol = VolumeResolver.volumeInfo(for: destFolder) else {
            throw NSError(domain: "PlannerEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to resolve destination volume info"])
        }
        let destRel = VolumeResolver.destRootRelpath(destFolder: destFolder, volumeRoot: destVol.rootURL)
        try db.setPlanDest(destVolumeUUID: destVol.uuid, destLabel: destVol.name, destRootRelpath: destRel)
        await log("DEST volume uuid=\(destVol.uuid) root=\(destVol.rootURL.path) rel=\(destRel)")

        // Insert sources
        var sourceIDs: [(SourceItem, Int64)] = []
        for s in sources {
            let sid = try db.insertSource(kind: s.kind.rawValue, inputPath: s.url.path)
            sourceIDs.append((s, sid))
        }

        // Prepare insert statement
        let insertStmt = try db.prepareInsertFile()
        defer { db.finalize(insertStmt) }

        // Scan + hash (Parallel with bounded queue)
        prog.stage = .hashing
        await progress(prog)

        try db.begin()
        var txCount = 0

        try await withThrowingTaskGroup(of: ScanResult?.self) { group in
            let MAX_CONCURRENCY = 8
            var activeTasks = 0

            for (s, sid) in sourceIDs {
                if Task.isCancelled { break }
                
                await log("Scanning \(s.kind.rawValue): \(s.url.path)")
                let roots = resolveScanRoots(for: s)
                if roots.isEmpty {
                   await log("WARN: No scan root found for source: \(s.url.path)")
                   continue
                }

                for root in roots {
                    let fm = FileManager.default
                    let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
                    let opts: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles, .skipsPackageDescendants]

                    guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: opts) else {
                       await log("ERROR: Failed to enumerate: \(root.path)")
                        prog.errorCount += 1
                        await progress(prog)
                        continue
                    }

                    for case let fileURL as URL in enumerator {
                        if Task.isCancelled { break }

                         do {
                            let rv = try fileURL.resourceValues(forKeys: Set(keys))
                            if rv.isSymbolicLink == true { continue }
                            if rv.isDirectory == true { continue }
                            guard rv.isRegularFile == true else { continue }

                            let ext = fileURL.pathExtension.lowercased()
                            if !imageExts.contains(ext) { continue }

                            guard let vol = VolumeResolver.volumeInfo(for: fileURL) else { continue }
                            let rel = VolumeResolver.relPath(of: fileURL, volumeRoot: vol.rootURL)
                            let size = Int64(rv.fileSize ?? 0)
                            let mtime = Int64((rv.contentModificationDate ?? Date(timeIntervalSince1970: 0)).timeIntervalSince1970)

                            prog.discoveredFiles += 1
                            prog.currentPath = fileURL.path
                            // Don't await progress update here excessively to avoid stalling loop? 
                            // Actually it is fine, but maybe throttle?
                            // For simplicity, just update.

                            // Wait if queue full
                            if activeTasks >= MAX_CONCURRENCY {
                                if let res = try await group.next() {
                                    activeTasks -= 1
                                    if let r = res {
                                        try await writeResult(r)
                                    }
                                }
                            }
                            
                            activeTasks += 1
                            group.addTask {
                                if Task.isCancelled { return nil }
                                // Hash
                                let (hex, bytesRead) = try SHA256Hasher.sha256Hex(of: fileURL) { _ in }
                                return ScanResult(fileURL: fileURL, relPath: rel, volumeUUID: vol.uuid, size: size, mtime: mtime, sid: sid, sha256: hex, bytesRead: bytesRead)
                            }

                         } catch {
                             prog.errorCount += 1
                             await log("ERROR: \(error.localizedDescription) at \(fileURL.path)")
                             await progress(prog)
                         }
                    }
                }
            }
            
            // Drain remaining
            while let res = try await group.next() {
                 if let r = res {
                     try await writeResult(r)
                 }
            }

            func writeResult(_ r: ScanResult) async throws {
                prog.hashedFiles += 1
                prog.totalBytesRead += r.bytesRead
                prog.currentPath = r.fileURL.path
                await progress(prog)

                try db.insertFile(
                    stmt: insertStmt,
                    sourceID: r.sid,
                    volumeUUID: r.volumeUUID,
                    relPath: r.relPath,
                    filename: r.fileURL.lastPathComponent,
                    ext: r.fileURL.pathExtension.lowercased(),
                    kind: "IMAGE",
                    sizeBytes: r.size,
                    mtimeEpoch: r.mtime,
                    inode: nil,
                    isSymlink: false,
                    isCandidate: true,
                    sha256: r.sha256,
                    hashStatus: "DONE",
                    hashError: nil
                )
                txCount += 1
                if txCount >= 2000 {
                    try db.commit()
                    try db.begin()
                    txCount = 0
                    await log("DB commit checkpoint (files inserted)")
                }
            }
        }
        
        try db.commit()

        // Build blobs (canonical only) + date
        prog.stage = .buildingBlobs
        prog.currentPath = ""
        await progress(prog)

        let exif = ExifDateExtractor()
        let candidates = try db.canonicalCandidates()
        var usedDestPaths: Set<String> = []
        
        let blobStmt = try db.prepareInsertBlob()
        defer { db.finalize(blobStmt) }

        try db.begin()
        txCount = 0

        for c in candidates {
            if Task.isCancelled { throw CancellationError() }

            // resolve absolute path for canonical
            guard let mount = VolumeResolver.mountURL(forVolumeUUID: c.volumeUUID) else {
                prog.errorCount += 1
                await log("ERROR: volume not mounted for UUID \(c.volumeUUID) (sha256=\(c.sha256))")
                continue
            }
            let abs = mount.appendingPathComponent(c.relPath)
            prog.currentPath = abs.path
            await progress(prog)

            // date
            let ymd: String
            let source: String
            if let exifYMD = exif.exifDateYMD(abs) {
                ymd = exifYMD
                source = "EXIF"
            } else {
                ymd = ExifDateExtractor.ymdFromEpochUTC(c.mtime)
                source = "MTIME"
            }

            // build dest path: YYYY/MM/DD/<filename>
            // We must handle collisions (different hash/content, same filename & date)
            
            let parts = ymd.split(separator: "-")
            let yyyy = parts.count > 0 ? String(parts[0]) : "1970"
            let mm = parts.count > 1 ? String(parts[1]) : "01"
            let dd = parts.count > 2 ? String(parts[2]) : "01"
            let destRelDir = "\(yyyy)/\(mm)/\(dd)"
            
            let baseName: String
            let ext: String
            
            if c.filename.contains(".") {
                baseName = (c.filename as NSString).deletingPathExtension
                ext = (c.filename as NSString).pathExtension
            } else {
                baseName = c.filename
                ext = ""
            }
            
            var candidateName = c.filename
            var counter = 2
            
            // Collision resolution loop
            while usedDestPaths.contains("\(destRelDir)/\(candidateName)") {
                if ext.isEmpty {
                    candidateName = "\(baseName)_v\(counter)"
                } else {
                    candidateName = "\(baseName)_v\(counter).\(ext)"
                }
                counter += 1
            }
            
            let destRelPath = "\(destRelDir)/\(candidateName)"
            usedDestPaths.insert(destRelPath)

            try db.insertBlob(
                stmt: blobStmt,
                sha256: c.sha256,
                size: c.size,
                canonicalFileID: c.fileID,
                canonicalFilename: c.filename,
                archiveYMD: ymd,
                archiveSource: source,
                destRelDir: destRelDir, // No longer contains hash
                destRelPath: destRelPath
            )

            txCount += 1
            if txCount >= 1000 {
                try db.commit()
                try db.begin()
                txCount = 0
                await log("DB commit checkpoint (blobs inserted)")
            }
        }

        try db.commit()

        // file_blob + ops
        try db.buildFileBlobTable()
        try db.buildOpsTable()

        prog.uniqueBlobs = try db.countBlobs()
        prog.duplicateCount = prog.hashedFiles - prog.uniqueBlobs
        await progress(prog)
        await log("Unique blobs (COPY ops): \(prog.uniqueBlobs)")

        // freeze
        prog.stage = .freezing
        await progress(prog)
        try db.freezePlan()
        await log("Plan frozen (FROZEN). DB: \(dbURL.path)")
    }

    /// Determine scan roots:
    /// - For folders: the folder itself
    /// - For libraries: search for 'Originals' or 'Masters' within the package
    private func resolveScanRoots(for source: SourceItem) -> [URL] {
        switch source.kind {
        case .folder:
            return [source.url]
        case .library:
            // try direct children
            let candidates = ["Originals", "Masters", "Masters.legacy"]
            for name in candidates {
                let u = source.url.appendingPathComponent(name, isDirectory: true)
                if FileManager.default.fileExists(atPath: u.path) {
                    return [u]
                }
            }
            // try find in package (depth-limited)
            let fm = FileManager.default
            let opts: FileManager.DirectoryEnumerationOptions = [.skipsHiddenFiles]
            if let en = fm.enumerator(at: source.url, includingPropertiesForKeys: [.isDirectoryKey], options: opts) {
                for case let u as URL in en {
                    if candidates.contains(u.lastPathComponent) && FileManager.default.fileExists(atPath: u.path) {
                        return [u]
                    }
                    // avoid deep scan (best-effort). stop after certain depth
                    let depth = u.pathComponents.count - source.url.pathComponents.count
                    if depth > 6 {
                        en.skipDescendants()
                    }
                }
            }
            return []
        }
    }
}
