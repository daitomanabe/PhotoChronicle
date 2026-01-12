# Architecture Summary

## 1. Processing Sequence (Current Logic)

The current implementation performs a full hash generation *before* any database interaction for each file.

```mermaid
graph TD
    A[Enumerate File (FileManager)] --> B{Extension Check};
    B -- Match --> C[**Full SHA-256 Hash** (Read entire file)];
    C --> D[Insert into DB (INSERT OR IGNORE)];
    D --> E{Commit Batch?};
    E -- Yes --> F[Commit Transaction];
```

**Note**: There is no "Check DB" step before Hashing.

## 2. Table Schema: `files`

```sql
CREATE TABLE IF NOT EXISTS files (
  file_id INTEGER PRIMARY KEY,
  source_id INTEGER NOT NULL REFERENCES sources(source_id) ON DELETE CASCADE,

  volume_uuid TEXT NOT NULL,
  rel_path TEXT NOT NULL,
  filename TEXT NOT NULL,
  ext TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT 'IMAGE' CHECK(kind IN ('IMAGE','VIDEO','OTHER')),

  size_bytes INTEGER NOT NULL,
  mtime_epoch INTEGER NOT NULL,
  inode INTEGER,
  is_symlink INTEGER NOT NULL DEFAULT 0 CHECK(is_symlink IN (0,1)),

  is_candidate INTEGER NOT NULL DEFAULT 1 CHECK(is_candidate IN (0,1)),
  discovered_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),

  sha256 TEXT,
  hash_status TEXT NOT NULL DEFAULT 'PENDING'
    CHECK(hash_status IN ('PENDING','HASHING','DONE','ERROR')),
  hash_error TEXT,

  UNIQUE(volume_uuid, rel_path)
);
```

**Indices**:
- `idx_files_source_id`
- `idx_files_filename`
- `idx_files_sha256`
- `idx_files_size_mtime`

## 3. Deduplication Logic (Candidate Extraction)

The system identifies "Canonical" files using a `GROUP BY sha256` in a Common Table Expression (CTE), then `JOIN`s back to the main table.

```sql
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
```
