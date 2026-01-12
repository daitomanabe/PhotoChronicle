# PhotoChronicle

**Scalable Photo Archive Planner & Executor with deduplication, integrity verification, and "Fast Copy" parallel processing.**

PhotoChronicle is a native macOS application (SwiftUI) designed for archiving massive photo libraries. It scans multiple source directories (including macOS Photos Libraries), identifies unique files by content hash (SHA-256), and safely copies them to a structured destination archive (`YYYY/MM/DD` format) with collision handling.

## Features

-   **Deep Scanning**: Recursively scans folders and macOS Photos Library bundles (`.photolibrary/Originals`).
-   **Content-Addressable Deduplication**: Uses SHA-256 scanning to identify duplicate files regardless of filename.
-   **Video Support**: Archives video files (MTS, AVI, MOV, MP4, etc.) in addition to photos.
-   **Selectable Media Types**: Choose to scan only "Images", only "Videos", or both.
-   **Structured Archival**: Automatically organizes files into a `YYYY/MM/DD` folder structure based on EXIF/Metadata or file modification time.
-   **Phase 1 (Analysis)**: Scans and builds a "Plan" (SQLite database) safely without modifying any files.
-   **Phase 2 (Execution)**: Executes the plan with robust safety features:
    -   **Atomic Batch Reservation**: Thread-safe parallel execution logic.
    -   **Fast Copy**: Configurable concurrency (up to 8 threads) for high-speed transfer.
    -   **Circuit Breaker**: Auto-stops after 5 consecutive errors to protect NAS/HDD.
    -   **Resumable**: Execution state is saved in SQLite; can be safely paused and resumed.
-   **Safety First**:
    -   Verifies source file existence before copy.
    -   Resolves filename collisions (e.g., `IMG_001_v2.JPG`).
    -   Detailed debug logging.

## Tech Stack

-   **Language**: Swift 5.10 / 6.0
-   **UI Framework**: SwiftUI (macOS)
-   **Database**: SQLite (via direct C-API wrapper `PlanDB`)
-   **Concurrency**: Swift Concurrency (`TaskGroup`, `MainActor`)

## Building

```bash
# Build binary
swift build -c release

# Package (Create .app and .dmg)
./scripts/package.sh
```

## Usage

1.  **Plan Database**: Create a new `.sqlite` plan file.
2.  **Sources**: Drag and drop folders or Photo Libraries to scan.
3.  **Destination**: Select the target drive/folder for the archive.
4.  **Phase 1**: Click "Start Phase 1" to scan and generate the copy plan.
5.  **Phase 2**: Review the plan stats, select "Fast" or "Safe" mode, and click "Start Phase 2" to begin copying.

## License

MIT License. Copyright (c) 2026 Daito Manabe.
