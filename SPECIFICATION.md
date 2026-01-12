# PhotoChronicle Technical Specification

## 1. System Overview

PhotoChronicle is a macOS native application designed for the high-integrity archival of large media collections. It employs a two-phase architecture to separate analysis (Phase 1) from execution (Phase 2), ensuring that no file modifications occur until a complete, verified plan is generated.

### 1.1 Architecture
-   **UI Layer**: built with **SwiftUI**. Follows the MVVM (Model-View-ViewModel) pattern.
    -   `ContentView`: Main view with tabbed workflow.
    -   `PlannerViewModel`: Manages application state, navigation, and binds UI to the Logic Layer.
-   **Logic Layer**:
    -   `PlannerEngine`: Handles scanning, hashing, and plan generation (Phase 1).
    -   `Phase2Executor`: Manages file copying, verification, and error handling (Phase 2).
-   **Data Layer**:
    -   `PlanDB`: A direct wrapper around **SQLite** (C-API). Manages persistence of the file index (`files`), unique content (`blobs`), and copy operations (`ops`).

### 1.2 Concurrency Model
-   **Swift Concurrency**: Heavily utilizes `async/await`, `Task`, and `TaskGroup`.
-   **Phase 1 (Scanning)**: Uses `TaskGroup` to parallelize file hashing (SHA-256) with a bounded concurrency limit (default: 8 workers) to balance CPU usage and disk I/O.
-   **Phase 2 (Copying)**: Uses `TaskGroup` to run parallel copy workers.
-   **Database Safety**: SQLite is configured in **WAL (Write-Ahead Logging)** mode. Each concurrent worker instantiates its own `PlanDB` connection to avoid threading violations, relying on SQLite's internal locking for safety.

---

## 2. Database Schema

The core of the system is a SQLite database (`plan.sqlite`) that acts as both the working memory and the persistent save file.

### 2.1 Tables

#### `sources`
Tracks the input directories or libraries.
-   `id`: Primary Key
-   `kind`: 'FOLDER' or 'LIBRARY'
-   `path`: Absolute path to the source

#### `files`
Raw inventory of every scanned file.
-   `id`: Primary Key
-   `sha256`: Hex string of file content hash (Index)
-   `size_bytes`: File size
-   `mtime_epoch`: Modification time
-   `rel_path`: Path relative to source root
-   `source_id`: FK to `sources`
-   `kind`: 'IMAGE' or 'VIDEO' (derived from extension)

#### `blobs`
Represents unique content (Canonical Files).
-   `sha256`: Primary Key (Content Addressable) and unique constraint.
-   `canonical_file_id`: FK to one user-chosen representative file (e.g., shortest path).
-   `archive_ymd`: The determined target date (YYYY-MM-DD).
-   `dest_rel_path`: The final calculated destination path (handling collisions).

#### `ops`
The execution plan (Copy Instructions).
-   `id`: Primary Key
-   `op_type`: 'COPY'
-   `status`: 'PENDING', 'DONE', 'SKIPPED', 'ERROR'
-   `src_rel_path`, `dest_rel_path`: Source and destination paths.
-   `sha256`: Expected hash for verification.

---

## 3. Core Algorithms

### 3.1 Deduplication
Deduplication is **Content-Addressable**.
1.  **Hash**: Every file is hashed using **SHA-256**.
2.  **Group**: Files with identical hashes are grouped together.
3.  **Canonical Selection**: One file from the group is selected as the "Canonical" source (usually the first one scanned or shortest path).
4.  **Result**: Only one copy operation is generated per unique hash, regardless of how many duplicates exist in sources.

### 3.2 Date Extraction
The target folder structure (`YYYY/MM/DD`) is determined by the "Best Available Date".
1.  **Video Files** (`MTS`, `MP4`, `MOV`, etc.):
    -   Attempt to read **Creation Date** from QuickTime/ISO metadata using `AVFoundation`.
    -   Fallback: File Modification Time (**MTIME**).
2.  **Image Files** (`JPG`, `HEIC`, `RAW`):
    -   Attempt to read **EXIF DateTimeOriginal**.
    -   Fallback: EXIF DateTimeDigitized, then TIFF DateTime.
    -   Fallback: File Modification Time (**MTIME**).

### 3.3 Collision Resolution
If two different files (different hashes) map to the exact same destination path (e.g., same date, same filename `IMG_0001.JPG`), a suffix is appended to the *filename* (not extension) to preserve both.
-   Algorithm: `Original.jpg` -> `Original_v2.jpg` -> `Original_v3.jpg`.
-   This ensures no data loss occurs due to naming conflicts.

---

## 4. Phase 2 execution

### 4.1 "Safe" vs "Fast"
-   **Safe Mode**: Serial execution (1 worker). Minimal system load.
-   **Fast Mode**: Parallel execution (default 4-8 workers). Optimized for SSDs.

### 4.2 Verification
Integrity is paramount.
1.  **Pre-Copy**: Check if source file still exists.
2.  **Copy**: Perform file copy using `FileManager`, preserving attributes (Creation/Modification dates).
3.  **Post-Copy Verification**: Read the *Destination* file, calculate its SHA-256 hash, and compare it against the expected hash in the database.
4.  **Result**: Mark as `DONE` only if hashes match.

### 4.3 Circuit Breaker
To prevent cascading failures (e.g., destination drive disconnects):
-   The executor tracks consecutive errors.
-   **Limit**: If **5 consecutive errors** occur, the entire batch process halts immediately.

---

## 5. Security & Safety Mechanisms

-   **Deep Rescue**: Recursively scans into `.photolibrary` bundles to rescue original assets (looking for `Originals` or `Masters` folders) without corrupting the library structure itself.
-   **Read-Only Sources**: The application **NEVER** modifies, deletes, or moves source files. It only performs read operations.
-   **Transactional Database**: Plan generation commits in batches (every 1000-2000 items) to keep memory usage low and prevent data loss during long scans.
