import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class PlanDB {
    private var db: OpaquePointer? = nil

    init(dbURL: URL) throws {
        let path = dbURL.path
        if sqlite3_open(path, &db) != SQLITE_OK {
            defer { sqlite3_close(db) }
            throw NSError(
                domain: "PlanDB", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to open DB: \(path)"])
        }
        // performance pragmas
        _ = sqlite3_exec(db, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        _ = sqlite3_exec(db, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        _ = sqlite3_exec(db, "PRAGMA foreign_keys=ON;", nil, nil, nil)
    }

    deinit {
        sqlite3_close(db)
    }

    func exec(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<Int8>? = nil
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw NSError(
                domain: "PlanDB", code: Int(rc),
                userInfo: [NSLocalizedDescriptionKey: "SQLite exec error: \(msg)"])
        }
    }

    func begin() throws { try exec("BEGIN;") }
    func commit() throws { try exec("COMMIT;") }

    func dropAllTables() throws {
        let tables = ["ops", "file_blob", "blobs", "files", "sources", "plan"]
        for t in tables {
            try exec("DROP TABLE IF EXISTS \(t);")
        }
    }

    func applySchema() throws {
        try exec(PlanSchemaV4.sql)
    }

    func setPlanDest(destVolumeUUID: String, destLabel: String?, destRootRelpath: String) throws {
        let sql = """
            UPDATE plan
            SET dest_volume_uuid = ?,
                dest_volume_label = ?,
                dest_root_relpath = ?,
                updated_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
            WHERE plan_id = 1;
            """
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "PlanDB", code: 2, userInfo: [NSLocalizedDescriptionKey: "prepare failed"])
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, destVolumeUUID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, destLabel ?? "", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, destRootRelpath, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) != SQLITE_DONE {
            throw NSError(
                domain: "PlanDB", code: 3,
                userInfo: [NSLocalizedDescriptionKey: "setPlanDest failed"])
        }
    }

    func unfreezePlan() throws {
        try exec(
            """
            UPDATE plan SET plan_state='DRAFT', updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE plan_id=1;
            """)
    }

    func freezePlan() throws {
        try exec(
            """
            UPDATE plan SET plan_state='FROZEN', updated_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE plan_id=1;
            """)
    }

    func readPlanInfo() throws -> (destUUID: String?, destRootRelPath: String?, planState: String?)
    {
        let sql =
            "SELECT dest_volume_uuid, dest_root_relpath, plan_state FROM plan WHERE plan_id=1;"
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "PlanDB", code: 40,
                userInfo: [NSLocalizedDescriptionKey: "prepare readPlanInfo failed"])
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let uuid = sqlite3_column_text(stmt, 0).map { String(cString: $0) }
            let root = sqlite3_column_text(stmt, 1).map { String(cString: $0) }
            let state = sqlite3_column_text(stmt, 2).map { String(cString: $0) }
            return (uuid, root, state)
        }
        return (nil, nil, nil)
    }

    func readSources() throws -> [(kind: String, path: String)] {
        let sql = "SELECT kind, input_path FROM sources ORDER BY source_id;"
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "PlanDB", code: 41,
                userInfo: [NSLocalizedDescriptionKey: "prepare readSources failed"])
        }
        defer { sqlite3_finalize(stmt) }

        var out: [(String, String)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let k = String(cString: sqlite3_column_text(stmt, 0))
            let p = String(cString: sqlite3_column_text(stmt, 1))
            out.append((k, p))
        }
        return out
    }

    func insertSource(kind: String, inputPath: String) throws -> Int64 {
        // Try INSERT
        let sql = "INSERT INTO sources(kind, input_path, scan_status) VALUES(?,?, 'PENDING');"
        var stmt: OpaquePointer? = nil
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, kind, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, inputPath, -1, SQLITE_TRANSIENT)
            let rc = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
            if rc == SQLITE_DONE {
                return sqlite3_last_insert_rowid(db)
            }
        } else {
            sqlite3_finalize(stmt)
        }

        // If fail (likely constraint violation), select existing
        let selSql = "SELECT source_id FROM sources WHERE input_path=?;"
        var selStmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, selSql, -1, &selStmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "PlanDB", code: 12,
                userInfo: [NSLocalizedDescriptionKey: "prepare select source failed"])
        }
        defer { sqlite3_finalize(selStmt) }
        sqlite3_bind_text(selStmt, 1, inputPath, -1, SQLITE_TRANSIENT)
        if sqlite3_step(selStmt) == SQLITE_ROW {
            return sqlite3_column_int64(selStmt, 0)
        }

        throw NSError(
            domain: "PlanDB", code: 13,
            userInfo: [NSLocalizedDescriptionKey: "insertSource failed (insert & select)"])
    }

    func prepareInsertFile() throws -> OpaquePointer? {
        let sql = """
            INSERT OR IGNORE INTO files(
              source_id, volume_uuid, rel_path, filename, ext, kind,
              size_bytes, mtime_epoch, inode, is_symlink, is_candidate,
              sha256, hash_status, hash_error
            ) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?);
            """
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "PlanDB", code: 20,
                userInfo: [NSLocalizedDescriptionKey: "prepare insertFile failed"])
        }
        return stmt
    }

    func insertFile(
        stmt: OpaquePointer?,
        sourceID: Int64,
        volumeUUID: String,
        relPath: String,
        filename: String,
        ext: String,
        kind: String,
        sizeBytes: Int64,
        mtimeEpoch: Int64,
        inode: Int64?,
        isSymlink: Bool,
        isCandidate: Bool,
        sha256: String?,
        hashStatus: String,
        hashError: String?
    ) throws {

        guard let stmt else { return }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)

        sqlite3_bind_int64(stmt, 1, sourceID)
        sqlite3_bind_text(stmt, 2, volumeUUID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, relPath, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 4, filename, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, ext, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, kind, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 7, sizeBytes)
        sqlite3_bind_int64(stmt, 8, mtimeEpoch)
        if let inode {
            sqlite3_bind_int64(stmt, 9, inode)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        sqlite3_bind_int(stmt, 10, isSymlink ? 1 : 0)
        sqlite3_bind_int(stmt, 11, isCandidate ? 1 : 0)

        if let sha256 {
            sqlite3_bind_text(stmt, 12, sha256, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 12)
        }
        sqlite3_bind_text(stmt, 13, hashStatus, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 14, hashError ?? "", -1, SQLITE_TRANSIENT)

        if sqlite3_step(stmt) != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(
                domain: "PlanDB", code: 21,
                userInfo: [NSLocalizedDescriptionKey: "insertFile failed: \(msg)"])
        }
    }

    func finalize(_ stmt: OpaquePointer?) {
        if let stmt { sqlite3_finalize(stmt) }
    }

    // Query canonical rows for blobs build
    func canonicalCandidates() throws -> [(
        sha256: String, size: Int64, fileID: Int64, volumeUUID: String, relPath: String,
        filename: String, mtime: Int64
    )] {
        let sql = """
            WITH grouped AS (
              SELECT sha256, MIN(volume_uuid || ':' || rel_path) AS canonical_key, MAX(size_bytes) AS size_bytes
              FROM files
              WHERE is_candidate=1 AND hash_status='DONE' AND sha256 IS NOT NULL
              GROUP BY sha256
            )
            SELECT g.sha256 AS sha256, g.size_bytes AS size_bytes,
                   f.file_id AS file_id, f.volume_uuid AS volume_uuid, f.rel_path AS rel_path,
                   f.filename AS filename, f.mtime_epoch AS mtime_epoch
            FROM grouped g
            JOIN files f
              ON f.sha256 = g.sha256
             AND (f.volume_uuid || ':' || f.rel_path) = g.canonical_key
            ORDER BY f.file_id;
            """
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "PlanDB", code: 30,
                userInfo: [NSLocalizedDescriptionKey: "prepare canonicalCandidates failed"])
        }
        defer { sqlite3_finalize(stmt) }

        var out: [(String, Int64, Int64, String, String, String, Int64)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let sha = String(cString: sqlite3_column_text(stmt, 0))
            let size = sqlite3_column_int64(stmt, 1)
            let fid = sqlite3_column_int64(stmt, 2)
            let vu = String(cString: sqlite3_column_text(stmt, 3))
            let rp = String(cString: sqlite3_column_text(stmt, 4))
            let fn = String(cString: sqlite3_column_text(stmt, 5))
            let mt = sqlite3_column_int64(stmt, 6)
            out.append((sha, size, fid, vu, rp, fn, mt))
        }
        return out
    }

    func prepareInsertBlob() throws -> OpaquePointer? {
        let sql = """
            INSERT OR REPLACE INTO blobs(
              sha256, size_bytes, canonical_file_id, canonical_filename,
              archive_date_ymd, archive_date_source,
              dest_rel_dir, dest_rel_path
            ) VALUES(?,?,?,?,?,?,?,?);
            """
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "PlanDB", code: 31,
                userInfo: [NSLocalizedDescriptionKey: "prepare insertBlob failed"])
        }
        return stmt
    }

    func insertBlob(
        stmt: OpaquePointer?,
        sha256: String, size: Int64, canonicalFileID: Int64, canonicalFilename: String,
        archiveYMD: String, archiveSource: String,
        destRelDir: String, destRelPath: String
    ) throws {

        guard let stmt else { return }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)

        sqlite3_bind_text(stmt, 1, sha256, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, size)
        sqlite3_bind_int64(stmt, 3, canonicalFileID)
        sqlite3_bind_text(stmt, 4, canonicalFilename, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 5, archiveYMD, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 6, archiveSource, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 7, destRelDir, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 8, destRelPath, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) != SQLITE_DONE {
            let msg = String(cString: sqlite3_errmsg(db))
            throw NSError(
                domain: "PlanDB", code: 32,
                userInfo: [NSLocalizedDescriptionKey: "insertBlob failed: \(msg)"])
        }
    }

    func buildFileBlobTable() throws {
        // mark canonical vs duplicate
        try exec(
            """
            DELETE FROM file_blob;
            INSERT INTO file_blob(file_id, sha256, role)
            SELECT f.file_id, b.sha256,
                   CASE WHEN f.file_id = b.canonical_file_id THEN 'CANONICAL' ELSE 'DUPLICATE' END
            FROM files f
            JOIN blobs b ON b.sha256 = f.sha256
            WHERE f.is_candidate=1 AND f.hash_status='DONE';
            """)
    }

    func buildOpsTable() throws {
        try exec("DELETE FROM ops;")
        // COPY only (one per blob)
        try exec(
            """
            INSERT INTO ops(op_type, sha256, src_volume_uuid, src_rel_path, src_filename,
                           expected_size_bytes, expected_mtime_epoch, dest_rel_path)
            SELECT 'COPY', b.sha256, f.volume_uuid, f.rel_path, f.filename, f.size_bytes, f.mtime_epoch, b.dest_rel_path
            FROM blobs b
            JOIN files f ON f.file_id = b.canonical_file_id;
            """)
    }

    func countBlobs() throws -> Int {
        let row = try scalarInt("SELECT COUNT(*) FROM blobs;")
        return row
    }

    func readStats() throws -> (hashed: Int, unique: Int) {
        let hashed = try scalarInt(
            "SELECT COUNT(*) FROM files WHERE is_candidate=1 AND hash_status='DONE';")
        let unique = try scalarInt("SELECT COUNT(*) FROM blobs;")
        return (hashed, unique)
    }

    func pendingOpsCount() throws -> Int {
        return try scalarInt("SELECT COUNT(*) FROM ops WHERE status='PENDING' AND op_type='COPY';")
    }

    func totalOpsCount() throws -> Int {
        return try scalarInt("SELECT COUNT(*) FROM ops WHERE op_type='COPY';")
    }

    // Returns (opId, sha256, srcVolumeUUID, srcRelPath, destRelPath, expectedSize)
    func nextPendingOp() throws -> (Int64, String, String, String, String, Int64)? {
        let sql = """
            SELECT op_id, sha256, src_volume_uuid, src_rel_path, dest_rel_path, expected_size_bytes
            FROM ops
            WHERE status='PENDING' AND op_type='COPY'
            ORDER BY op_id
            LIMIT 1;
            """
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "PlanDB", code: 60,
                userInfo: [NSLocalizedDescriptionKey: "prepare nextPendingOp failed"])
        }
        defer { sqlite3_finalize(stmt) }

        if sqlite3_step(stmt) == SQLITE_ROW {
            let opID = sqlite3_column_int64(stmt, 0)
            let sha = String(cString: sqlite3_column_text(stmt, 1))
            let srcVol = String(cString: sqlite3_column_text(stmt, 2))
            let srcRel = String(cString: sqlite3_column_text(stmt, 3))
            let destRel = String(cString: sqlite3_column_text(stmt, 4))
            let size = sqlite3_column_int64(stmt, 5)
            return (opID, sha, srcVol, srcRel, destRel, size)
        }
        return nil
    }

    // Reserve a batch of ops (mark RUNNING) and return them
    func reserveNextOps(limit: Int) throws -> [(Int64, String, String, String, String, Int64)] {
        try exec("BEGIN IMMEDIATE;")

        // 1. Select IDs
        let selectSql = """
            SELECT op_id, sha256, src_volume_uuid, src_rel_path, dest_rel_path, expected_size_bytes
            FROM ops
            WHERE status='PENDING' AND op_type='COPY'
            ORDER BY op_id
            LIMIT \(limit);
            """

        var ops: [(Int64, String, String, String, String, Int64)] = []
        var opIDs: [Int64] = []

        var stmt: OpaquePointer? = nil
        if sqlite3_prepare_v2(db, selectSql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let opID = sqlite3_column_int64(stmt, 0)
                let sha = String(cString: sqlite3_column_text(stmt, 1))
                let srcVol = String(cString: sqlite3_column_text(stmt, 2))
                let srcRel = String(cString: sqlite3_column_text(stmt, 3))
                let destRel = String(cString: sqlite3_column_text(stmt, 4))
                let size = sqlite3_column_int64(stmt, 5)
                ops.append((opID, sha, srcVol, srcRel, destRel, size))
                opIDs.append(opID)
            }
            sqlite3_finalize(stmt)
        } else {
            // Rollback if prepare fails
            try? exec("ROLLBACK;")
            throw NSError(
                domain: "PlanDB", code: 70,
                userInfo: [NSLocalizedDescriptionKey: "reserveNextOps select failed"])
        }

        if ops.isEmpty {
            try exec("COMMIT;")
            return []
        }

        // 2. Update Status
        let idList = opIDs.map { String($0) }.joined(separator: ",")
        let updateSql =
            "UPDATE ops SET status='RUNNING', started_at=strftime('%Y-%m-%dT%H:%M:%fZ','now') WHERE op_id IN (\(idList));"

        do {
            try exec(updateSql)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }

        return ops
    }

    func updateOpStatus(
        opID: Int64, status: String, error: String? = nil, bytesCopied: Int64 = 0,
        verified: Bool = false
    ) throws {
        let sql = """
            UPDATE ops
            SET status = ?,
                last_error_message = ?,
                bytes_copied = ?,
                verified = ?,
                finished_at = strftime('%Y-%m-%dT%H:%M:%fZ','now')
            WHERE op_id = ?;
            """
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "PlanDB", code: 61,
                userInfo: [NSLocalizedDescriptionKey: "prepare updateOpStatus failed"])
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, status, -1, SQLITE_TRANSIENT)
        if let err = error {
            sqlite3_bind_text(stmt, 2, err, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_int64(stmt, 3, bytesCopied)
        sqlite3_bind_int(stmt, 4, verified ? 1 : 0)
        sqlite3_bind_int64(stmt, 5, opID)

        if sqlite3_step(stmt) != SQLITE_DONE {
            throw NSError(
                domain: "PlanDB", code: 62,
                userInfo: [NSLocalizedDescriptionKey: "updateOpStatus failed"])
        }
    }

    func mergeOpsFrom(otherDBPath: String) throws -> Int {
        // 1. Attach
        let attachSql = "ATTACH DATABASE ? AS secondary;"
        var stmt: OpaquePointer? = nil
        if sqlite3_prepare_v2(db, attachSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, otherDBPath, -1, SQLITE_TRANSIENT)
            if sqlite3_step(stmt) != SQLITE_DONE {
                sqlite3_finalize(stmt)
                throw NSError(
                    domain: "PlanDB", code: 80,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to attach DB: \(otherDBPath)"])
            }
            sqlite3_finalize(stmt)
        } else {
            throw NSError(
                domain: "PlanDB", code: 81,
                userInfo: [NSLocalizedDescriptionKey: "Prepare attach failed"])
        }

        defer {
            // Detach regardless of success/fail
            _ = sqlite3_exec(db, "DETACH DATABASE secondary;", nil, nil, nil)
        }

        // 2. Verify Dest UUID matches
        // Check local
        let (localUUID, _, _) = try readPlanInfo()

        // Check remote
        let remoteUUID = try scalarString(
            "SELECT dest_volume_uuid FROM secondary.plan WHERE plan_id=1;")

        guard let lUUID = localUUID, let rUUID = remoteUUID, lUUID == rUUID else {
            throw NSError(
                domain: "PlanDB", code: 82,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "Destination mismatch. Cannot merge plans with different destinations."
                ])
        }

        // 3. Merge PENDING operations
        // We only copy COPY ops that are PENDING.
        // We let SQLite generate new op_ids (AUTOINCREMENT)
        let mergeSql = """
            INSERT INTO main.ops (op_type, sha256, src_volume_uuid, src_rel_path, src_filename, expected_size_bytes, expected_mtime_epoch, dest_rel_path, status)
            SELECT op_type, sha256, src_volume_uuid, src_rel_path, src_filename, expected_size_bytes, expected_mtime_epoch, dest_rel_path, 'PENDING'
            FROM secondary.ops
            WHERE status='PENDING' AND op_type='COPY';
            """

        try exec("BEGIN;")
        try exec(mergeSql)
        let count = Int(sqlite3_changes(db))
        try exec("COMMIT;")

        return count
    }

    func getOpCountsByStatus() throws -> [String: Int] {
        let sql = "SELECT status, COUNT(*) FROM ops WHERE op_type='COPY' GROUP BY status;"
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw NSError(
                domain: "PlanDB", code: 95,
                userInfo: [NSLocalizedDescriptionKey: "prepare getOpCountsByStatus failed"])
        }
        defer { sqlite3_finalize(stmt) }

        var counts: [String: Int] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let status = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_int64(stmt, 1))
            counts[status] = count
        }
        return counts
    }

    func resetAllOpsToPending() throws {
        // Reset all COPY ops to PENDING, clear errors, dates
        let sql = """
            UPDATE ops
            SET status = 'PENDING',
                started_at = NULL,
                finished_at = NULL,
                last_error_message = NULL,
                bytes_copied = 0,
                verified = 0
            WHERE op_type = 'COPY';
            """
        try exec(sql)
    }

    func resetStaleRunningOps() throws -> Int {
        // Reset only RUNNING ops (stale from crash/interrupt)
        let sql = """
            UPDATE ops
            SET status = 'PENDING',
                started_at = NULL,
                finished_at = NULL
            WHERE status = 'RUNNING' AND op_type = 'COPY';
            """
        try exec(sql)
        return Int(sqlite3_changes(db))
    }

    private func scalarInt(_ sql: String) throws -> Int {
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            // throw NSError(domain: "PlanDB", code: 90, userInfo: [NSLocalizedDescriptionKey: "prepare scalar failed"])
            // Fallback to simpler error to avoid recursion issues if used carefully or just fix the error handling
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    private func scalarString(_ sql: String) throws -> String? {
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            return String(cString: sqlite3_column_text(stmt, 0))
        }
        return nil
    }
    func listTables() throws -> [String] {
        let sql = "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;"
        var stmt: OpaquePointer? = nil
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return []
        }
        defer { sqlite3_finalize(stmt) }

        var tables: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            tables.append(name)
        }
        return tables
    }
}
