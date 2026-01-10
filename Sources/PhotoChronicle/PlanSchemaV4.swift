import Foundation

enum PlanSchemaV4 {
    static let sql: String = """
    PRAGMA foreign_keys = ON;

    CREATE TABLE IF NOT EXISTS plan (
      plan_id INTEGER PRIMARY KEY CHECK(plan_id = 1),
      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      updated_at TEXT,
      plan_state TEXT NOT NULL DEFAULT 'DRAFT'
        CHECK(plan_state IN ('DRAFT','FROZEN')),

      dest_volume_uuid TEXT,
      dest_volume_label TEXT,
      dest_root_relpath TEXT NOT NULL,

      layout TEXT NOT NULL DEFAULT 'DATE_YYYY_MM_DD_SHA256_DIR_FILENAME'
        CHECK(layout IN ('DATE_YYYY_MM_DD_SHA256_DIR_FILENAME')),

      date_policy TEXT NOT NULL DEFAULT 'EXIF_THEN_MTIME'
        CHECK(date_policy IN ('EXIF_THEN_MTIME','MTIME_ONLY')),

      mtime_timezone TEXT NOT NULL DEFAULT 'UTC' CHECK(mtime_timezone IN ('UTC')),

      include_images INTEGER NOT NULL DEFAULT 1 CHECK(include_images IN (0,1)),
      include_videos INTEGER NOT NULL DEFAULT 0 CHECK(include_videos IN (0,1)),
      include_live_video INTEGER NOT NULL DEFAULT 0 CHECK(include_live_video IN (0,1)),

      copy_xattrs INTEGER NOT NULL DEFAULT 0 CHECK(copy_xattrs IN (0,1)),
      notes TEXT
    );
    INSERT OR IGNORE INTO plan(plan_id, dest_root_relpath) VALUES (1, 'PhotoArchive');

    CREATE TABLE IF NOT EXISTS sources (
      source_id INTEGER PRIMARY KEY,
      added_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      kind TEXT NOT NULL CHECK(kind IN ('LIBRARY','FOLDER')),
      input_path TEXT NOT NULL,
      volume_uuid TEXT,
      volume_label TEXT,
      mount_point TEXT,
      root_relpath TEXT,
      scan_status TEXT NOT NULL DEFAULT 'PENDING'
        CHECK(scan_status IN ('PENDING','SCANNING','SCANNED','ERROR')),
      scan_error TEXT
    );
    CREATE UNIQUE INDEX IF NOT EXISTS idx_sources_input_path ON sources(input_path);
    CREATE INDEX IF NOT EXISTS idx_sources_kind ON sources(kind);

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
    CREATE INDEX IF NOT EXISTS idx_files_source_id ON files(source_id);
    CREATE INDEX IF NOT EXISTS idx_files_filename ON files(filename);
    CREATE INDEX IF NOT EXISTS idx_files_sha256 ON files(sha256);
    CREATE INDEX IF NOT EXISTS idx_files_size_mtime ON files(size_bytes, mtime_epoch);

    CREATE TABLE IF NOT EXISTS blobs (
      sha256 TEXT PRIMARY KEY,
      size_bytes INTEGER NOT NULL,

      canonical_file_id INTEGER NOT NULL REFERENCES files(file_id),
      canonical_filename TEXT NOT NULL,

      archive_date_ymd TEXT NOT NULL,
      archive_date_source TEXT NOT NULL CHECK(archive_date_source IN ('EXIF','MTIME')),

      dest_rel_dir TEXT NOT NULL,
      dest_rel_path TEXT NOT NULL,

      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now'))
    );
    CREATE INDEX IF NOT EXISTS idx_blobs_canonical_file_id ON blobs(canonical_file_id);
    CREATE INDEX IF NOT EXISTS idx_blobs_archive_date ON blobs(archive_date_ymd);

    CREATE TABLE IF NOT EXISTS file_blob (
      file_id INTEGER NOT NULL REFERENCES files(file_id) ON DELETE CASCADE,
      sha256 TEXT NOT NULL REFERENCES blobs(sha256) ON DELETE CASCADE,
      role TEXT NOT NULL CHECK(role IN ('CANONICAL','DUPLICATE')),
      PRIMARY KEY(file_id, sha256)
    );
    CREATE INDEX IF NOT EXISTS idx_file_blob_sha256 ON file_blob(sha256);

    CREATE TABLE IF NOT EXISTS ops (
      op_id INTEGER PRIMARY KEY,
      op_type TEXT NOT NULL CHECK(op_type IN ('COPY','SKIP')),

      sha256 TEXT NOT NULL REFERENCES blobs(sha256),

      src_volume_uuid TEXT,
      src_rel_path TEXT,
      src_filename TEXT,
      expected_size_bytes INTEGER,
      expected_mtime_epoch INTEGER,

      dest_rel_path TEXT NOT NULL,

      status TEXT NOT NULL DEFAULT 'PENDING'
        CHECK(status IN ('PENDING','RUNNING','DONE','ERROR','SKIPPED','STALE')),

      attempt_count INTEGER NOT NULL DEFAULT 0,
      last_error_code TEXT,
      last_error_message TEXT,
      started_at TEXT,
      finished_at TEXT,
      bytes_copied INTEGER,
      verified INTEGER NOT NULL DEFAULT 0 CHECK(verified IN (0,1))
    );
    CREATE INDEX IF NOT EXISTS idx_ops_status ON ops(status);
    CREATE INDEX IF NOT EXISTS idx_ops_sha256 ON ops(sha256);
    CREATE INDEX IF NOT EXISTS idx_ops_dest_rel_path ON ops(dest_rel_path);
    CREATE INDEX IF NOT EXISTS idx_ops_src ON ops(src_volume_uuid, src_rel_path);

    CREATE TABLE IF NOT EXISTS op_events (
      event_id INTEGER PRIMARY KEY,
      op_id INTEGER REFERENCES ops(op_id) ON DELETE CASCADE,
      ts TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ','now')),
      level TEXT NOT NULL CHECK(level IN ('INFO','WARN','ERROR')),
      message TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_op_events_op_id ON op_events(op_id);
    """.trimmingCharacters(in: .whitespacesAndNewlines)
}
