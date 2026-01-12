# PhotoChronicle Performance Audit

**Date**: 2026-01-12
**Target**: `PlannerEngine.swift`, `PlanDB.swift`
**Status**: Review Only (No code changes applied)

## Executive Summary
The audit reveals **critical performance bottlenecks** that will prevent the application from scaling to large archives (TB+). The most severe issues are the **Lack of Incremental Scanning** (Point 9) and the **Full Hash Strategy** (Point 1). The application currently re-reads and re-hashes every file on every run, which is unsustainable for archival workflows.

| Point | Check Item | Logic Check | Severity | Findings |
| :--- | :--- | :--- | :--- | :--- |
| 1 | **Full Hash Strategy** | **YES** | 🔴 **Critical** | `SHA256Hasher` reads the full file stream immediately for every file. No size grouping or partial fingerprinting is performed. |
| 2 | **DB Transaction/Batch** | NO | 🟢 Safe | Transactions are correctly batched (2000 items per commit). |
| 3 | **Self-Join on Huge Table** | NO* | 🟡 Caution | Uses CTE + JOIN, which is O(N) *if indexed*. Acceptable for identifying canonicals, but depends on `files(sha256)` index. |
| 4 | **N+1 Selects** | NO | 🟢 Safe | No DB SELECTs inside the processing loop. Metadata is read from FS, which is necessary. |
| 5 | **Redundant I/O** | **YES** | 🟡 Warning | Files are opened/read once for Hashing (Full), and opened again for Exif (Header). |
| 6 | **Excessive Concurrency** | **YES** | 🔴 **High** | `MAX_CONCURRENCY` is hardcoded to 8. This will cause severe thrashing (IOPS saturation) on HDDs. |
| 7 | **Index Overhead** | **YES** | 🟡 Warning | Indexes likely remain active during the initial bulk insert, slowing down Phase 1. |
| 8 | **Text Primary Key** | NO | 🟢 Safe | `files` uses Integer PK. `blobs` uses SHA256 (Text) which is standard for CAS. |
| 9 | **Non-Incremental Scan** | **YES** | 💀 **Fatal** | **Critical Flaw**: The engine calculates the SHA-256 hash *before* checking if the file exists in the DB. It re-hashes the entire dataset on every run. |
| 10 | **No Metrics** | **YES** | 🟡 Warning | Basic counters exist, but per-stage timing and I/O throughput metrics are missing. |

---

## Detailed Findings

### 1. Full Hash Strategy (Fatal)
-   **Current**: `PlannerEngine` loop -> `SHA256Hasher.sha256Hex(of: fileURL)`.
-   **Impact**: Even for 100TB of data, it tries to read 100TB.
-   **Remediation**: Implement tiered checking:
    1.  **Size Check**: Only hash files that share a file size with another file. Unique sizes are implicitly unique content.
    2.  **Partial Hash**: Read first 4KB + middle 4KB. Compare.
    3.  **Full Hash**: Only if Partial Hash matches.

### 9. Incremental Scan (Fatal)
-   **Current**:
    ```swift
    // PlannerEngine.swift
    let (hex, ...) = try SHA256Hasher.sha256Hex(of: fileURL) // EXPENSIVE I/O
    try db.insertFile(..., sha256: hex) // INSERT OR IGNORE
    ```
-   **Impact**: 'Append' mode is effectively a full re-process. The database state is ignored during the scanning phase.
-   **Remediation**:
    -   Query DB for `(volume_uuid, rel_path)` matching `(mtime, size)` *before* hashing.
    -   If match found -> Skip hashing, mark as `SKIPPED_UNCHANGED`.

### 6. Concurrency Clashing
-   **Current**: `MAX_CONCURRENCY = 8`.
-   **Impact**: On spinning rust (HDDs), 8 concurrent seek/read streams reduce throughput to near zero (~10MB/s total vs 150MB/s serial).
-   **Remediation**: Make concurrency configurable. Default to 1 (Serial) for HDDs, 4-8 for SSDs.

### 5. Double I/O
-   **Current**: Hash (Full Read) -> Exif (Header Read).
-   **Impact**: Two file handle opens, two seek operations.
-   **Remediation**: Not critical compared to #1, but ideally Exif date would be extracted during the start of the Hash stream to share the file handle.

## Recommendations
1.  **Stop Full Hashing**: Implement Size-based grouping. 99% of files have unique sizes and never need hashing.
2.  **Fix Incremental Logic**: Check `PlanDB` before hashing.
3.  **Adaptive Concurrency**: Add a setting for "HDD Mode" (Serial).
