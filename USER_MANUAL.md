# PhotoChronicle - User Manual

## Overview
PhotoChronicle is a tool designed to consolidate large, disorganized photo/video collections into a clean, strictly chronological archive (YYYY/MM/DD) while performing deduplication using SHA-256 hashing.

## Workflow: The 5 Steps

The user interface is organized into **Step Cards** that guide you through the process sequentially.

### Step 1: Plan Database
The database stores all information about the scan, file hashes, and execution status.
- **Select Mode**:
  - **New**: Creates a fresh database (resets everything). Use this for a new archive project.
  - **Append**: Loads an existing database to add more sources to it.
- **Create / Save...**: Click to choose where to save your `.sqlite` file. **Recommendation**: Save this in the same folder as your source/destination logs for easy access.
- **Reveal in Finder**: Quickly find the active database file.

### Step 2: Sources (Input)
Add the locations you want to archive.
- **Drag & Drop**: Drag folders or Photos Libraries (`.photoslibrary`) into the box.
- **Recursive Scan**: Folders are scanned deeply.
- **Libraries**: Logic specifically looks for "Originals" or "Masters" folders inside libraries to avoid duplicates.

### Step 3: Destination (Output)
Select where the organized archive will be written.
- **Structure**: Files will be copied to `DEST_ROOT/YYYY/MM/DD/<filename>`.
- **Handling Duplicates**: 
  - If a file is a binary duplicate (same SHA-256) of one already in the archive or plan, it is skipped (Deduplication).
  - If a file has different content but the same filename/date, it is renamed with a version suffix (`_v2`, `_v3`).

### Step 4: Phase 1 (Scan & Analysis)
- **Start Phase 1**: logic:
  1.  Scans all sources.
  2.  Hashes every file (SHA-256).
  3.  Identifies unique files vs duplicates.
  4.  Determines the best date (EXIF `DateTimeOriginal` > File Modification Time).
  5.  Builds the "Plan" in the database.
- **Output**: The database is now "Frozen" and ready for execution.

### Step 5: Phase 2 (Execution)
- **Start Phase 2**: Executes the copy operations.
  - **Verification**: Every file is hashed *again* after copying to ensure 100% data integrity.
  - **Auto-Recovery**: If the app crashes or is stopped, simply click "Start Phase 2" again. It will automatically detect interrupted operations and resume safely.
- **Reset Ops**: A manual button to verify/monitor progress. If you suspect issues, you can "Reset All Ops" to force a full re-verification/copy pass.

## Troubleshooting

### "Phase 2 Error: 'ops' table missing"
- **Cause**: Phase 1 did not complete successfully, or you are opening a different database file than the one Phase 1 wrote to.
- **Fix**: Go to Step 1, ensure the correct DB is selected. Re-run Phase 1.

### "0 Pending Operations" but files missing
- **Cause**: The database thinks it finished, but files aren't there (e.g., deleted manually).
- **Fix**: Click **"Reset Phase 2 Ops (Retry All)"** in Step 5. Then click "Start Phase 2".

### Logs
- Detailed logs are shown at the bottom of the window.
- A permanent log file `phase2_execution_log.txt` is also written to your Destination folder during Phase 2.
