#!/usr/bin/env python3
"""
Photo Archive Phase 2 Executor (spec-final implementation)

- Reads a frozen plan SQLite DB produced by Phase 1
- Copies files into DEST_ROOT according to ops.dest_rel_path
- Preserves original filename (no rename)
- One file per sha256 (Phase 1 already de-duplicates by sha256 and created COPY ops)
- Atomic finalize (temp file -> os.replace)
- Default copy backend: stream copy (no xattrs/rsrc/acl) + SHA-256 calculated during copy
  => guarantees that the bytes written match ops.sha256, without an extra verification pass.

IMPORTANT SAFETY:
- NEVER moves or deletes sources
- NEVER overwrites an existing destination file (size mismatch -> ERROR)
"""

from __future__ import annotations

import argparse
import dataclasses
import errno
import hashlib
import os
import queue
import re
import signal
import sqlite3
import sys
import threading
import time
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple


# ----------------------------
# Error codes (stored in DB)
# ----------------------------
E_DEST_VOLUME_MISSING = "DEST_VOLUME_MISSING"
E_SRC_VOLUME_MISSING = "SRC_VOLUME_MISSING"
E_SRC_NOT_FOUND = "SRC_NOT_FOUND"
E_SRC_SIZE_CHANGED = "SRC_SIZE_CHANGED"
E_SRC_MTIME_CHANGED = "SRC_MTIME_CHANGED"
E_HASH_MISMATCH = "HASH_MISMATCH"
E_DEST_EXISTS_MISMATCH = "DEST_EXISTS_MISMATCH"
E_DISK_FULL = "DISK_FULL"
E_PERMISSION_DENIED = "PERMISSION_DENIED"
E_IO_ERROR = "IO_ERROR"
E_PLAN_INVALID = "PLAN_INVALID"
E_UNKNOWN = "UNKNOWN"

# Process exit codes
EXIT_OK = 0
EXIT_PARTIAL_ERROR = 10
EXIT_PLAN_INVALID = 20
EXIT_INTERRUPTED = 30
EXIT_FATAL = 40

# diskutil parsing
MOUNT_POINT_RE = re.compile(r"^\s*Mount Point:\s*(.+?)\s*$")
VOLUME_UUID_RE = re.compile(r"^\s*Volume UUID:\s*([0-9A-Fa-f-]+)\s*$")

_STOP_EVENT = threading.Event()


@dataclasses.dataclass(frozen=True)
class Plan:
    dest_volume_uuid: str
    dest_root_relpath: str
    plan_state: str


@dataclasses.dataclass(frozen=True)
class Op:
    op_id: int
    sha256: str
    src_volume_uuid: str
    src_rel_path: str
    src_filename: str
    expected_size: int
    expected_mtime: int
    dest_rel_path: str


@dataclasses.dataclass(frozen=True)
class Result:
    op_id: int
    status: str  # DONE / ERROR / STALE
    ok: bool
    error_code: Optional[str] = None
    error_message: Optional[str] = None
    bytes_copied: Optional[int] = None
    verified: int = 0  # 1 if sha256 verified, else 0


def _install_signal_handlers() -> None:
    def handler(signum, frame):
        _STOP_EVENT.set()
    signal.signal(signal.SIGINT, handler)
    signal.signal(signal.SIGTERM, handler)


def run_cmd(cmd: List[str]) -> Tuple[int, str, str]:
    import subprocess
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    out, err = p.communicate()
    return p.returncode, out, err


def diskutil_info(token: str) -> str:
    rc, out, err = run_cmd(["/usr/sbin/diskutil", "info", token])
    if rc != 0:
        raise RuntimeError(f"diskutil info failed ({rc}): {err.strip()}")
    return out


def mount_point_for_volume_uuid(volume_uuid: str) -> Optional[str]:
    try:
        out = diskutil_info(volume_uuid)
    except Exception:
        return None
    for line in out.splitlines():
        m = MOUNT_POINT_RE.match(line)
        if m:
            mp = m.group(1).strip()
            return mp if mp and mp != "Not mounted" else None
    return None


def connect_db(db_path: Path) -> sqlite3.Connection:
    con = sqlite3.connect(str(db_path))
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys=ON")
    con.execute("PRAGMA busy_timeout=5000")
    return con


def load_plan(con: sqlite3.Connection) -> Plan:
    row = con.execute(
        "SELECT dest_volume_uuid, dest_root_relpath, plan_state FROM plan WHERE plan_id=1"
    ).fetchone()
    if not row:
        raise ValueError("plan table missing row plan_id=1")
    return Plan(
        dest_volume_uuid=(row["dest_volume_uuid"] or "").strip(),
        dest_root_relpath=(row["dest_root_relpath"] or "").strip(),
        plan_state=(row["plan_state"] or "").strip(),
    )


def validate_plan(con: sqlite3.Connection, plan: Plan) -> List[str]:
    problems: List[str] = []
    if plan.plan_state != "FROZEN":
        problems.append(f"plan_state must be FROZEN (got {plan.plan_state!r})")
    if not plan.dest_volume_uuid:
        problems.append("dest_volume_uuid is required (plan.dest_volume_uuid)")
    if not plan.dest_root_relpath:
        problems.append("dest_root_relpath is required (plan.dest_root_relpath)")
    # Basic schema sanity: ensure ops table exists and has expected columns
    try:
        con.execute("SELECT op_id, op_type, sha256, src_volume_uuid, src_rel_path, expected_size_bytes, expected_mtime_epoch, dest_rel_path, status FROM ops LIMIT 1")
    except Exception as e:
        problems.append(f"ops table schema check failed: {e}")
    return problems


def is_safe_relpath(p: str) -> bool:
    if not p:
        return False
    if os.path.isabs(p):
        return False
    # Normalize separators to '/'
    parts = p.replace("\\", "/").split("/")
    if any(part in ("", ".", "..") for part in parts):
        return False
    return True


def join_under(root: Path, rel: str) -> Path:
    # root / rel, but refuse path traversal
    if not is_safe_relpath(rel):
        raise ValueError(f"unsafe relative path: {rel!r}")
    dest = (root / rel).resolve()
    root_res = root.resolve()
    try:
        common = os.path.commonpath([str(root_res), str(dest)])
    except Exception:
        raise ValueError("failed to validate destination path")
    if common != str(root_res):
        raise ValueError(f"path escapes root: rel={rel!r}")
    return dest


def reset_running(con: sqlite3.Connection) -> int:
    cur = con.execute("UPDATE ops SET status='PENDING' WHERE status='RUNNING'")
    con.commit()
    return cur.rowcount


def select_one_op(con: sqlite3.Connection, retry_errors: bool) -> Optional[Op]:
    statuses = ["PENDING"]
    if retry_errors:
        statuses.append("ERROR")
    qmarks = ",".join(["?"] * len(statuses))
    row = con.execute(
        f"""
        SELECT op_id, sha256, src_volume_uuid, src_rel_path, src_filename,
               expected_size_bytes AS expected_size,
               expected_mtime_epoch AS expected_mtime,
               dest_rel_path
        FROM ops
        WHERE op_type='COPY' AND status IN ({qmarks})
        ORDER BY op_id
        LIMIT 1
        """,
        tuple(statuses),
    ).fetchone()
    if not row:
        return None
    return Op(
        op_id=int(row["op_id"]),
        sha256=str(row["sha256"]),
        src_volume_uuid=str(row["src_volume_uuid"]),
        src_rel_path=str(row["src_rel_path"]),
        src_filename=str(row["src_filename"]),
        expected_size=int(row["expected_size"] or 0),
        expected_mtime=int(row["expected_mtime"] or 0),
        dest_rel_path=str(row["dest_rel_path"]),
    )


def mark_running(con: sqlite3.Connection, op_id: int, dry_run: bool) -> None:
    if dry_run:
        return
    con.execute(
        """
        UPDATE ops
        SET status='RUNNING',
            attempt_count=attempt_count+1,
            started_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),
            last_error_code=NULL,
            last_error_message=NULL
        WHERE op_id=? AND status IN ('PENDING','ERROR','STALE')
        """,
        (op_id,),
    )
    con.commit()


def update_result(con: sqlite3.Connection, res: Result, dry_run: bool) -> None:
    if dry_run:
        return
    con.execute(
        """
        UPDATE ops
        SET status=?,
            last_error_code=?,
            last_error_message=?,
            finished_at=strftime('%Y-%m-%dT%H:%M:%fZ','now'),
            bytes_copied=?,
            verified=?
        WHERE op_id=?
        """,
        (res.status, res.error_code, res.error_message, res.bytes_copied, res.verified, res.op_id),
    )
    con.commit()


def compute_sha256(path: Path, chunk_size: int = 8 * 1024 * 1024) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        while True:
            data = f.read(chunk_size)
            if not data:
                break
            h.update(data)
    return h.hexdigest()


def stream_copy_with_sha256(src: Path, dst_tmp: Path, expected_sha256: str,
                            chunk_size: int = 8 * 1024 * 1024) -> Tuple[bool, int, str]:
    """
    Copy src -> dst_tmp, computing sha256 as we read src.
    Returns: (ok, bytes_written, computed_sha256)
    """
    h = hashlib.sha256()
    total = 0
    with src.open("rb") as fsrc, dst_tmp.open("xb") as fdst:
        while True:
            if _STOP_EVENT.is_set():
                raise KeyboardInterrupt()
            data = fsrc.read(chunk_size)
            if not data:
                break
            fdst.write(data)
            h.update(data)
            total += len(data)
        fdst.flush()
        os.fsync(fdst.fileno())
    computed = h.hexdigest()
    return (computed.lower() == expected_sha256.lower(), total, computed)


def cleanup_tmp_prefix(dest_parent: Path, op_id: int) -> None:
    # best-effort cleanup of temp files from prior runs
    prefix = f".__tmpcopy__.op{op_id}."
    if not dest_parent.exists():
        return
    try:
        for p in dest_parent.iterdir():
            if p.is_file() and p.name.startswith(prefix):
                try:
                    p.unlink()
                except Exception:
                    pass
    except Exception:
        pass


def copy_one(op: Op, src_mount: str, dest_root_abs: Path,
             strict_mtime: bool,
             verify_existing: bool) -> Result:
    try:
        # Resolve paths safely
        src_abs = Path(src_mount) / op.src_rel_path
        dest_abs = join_under(dest_root_abs, op.dest_rel_path)
        dest_parent = dest_abs.parent

        # Check src existence
        if not src_abs.exists():
            return Result(op_id=op.op_id, ok=False, status="ERROR",
                          error_code=E_SRC_NOT_FOUND,
                          error_message=f"src missing: {src_abs}")

        st = src_abs.stat()
        # Size mismatch: treat as STALE immediately (very likely changed)
        if op.expected_size and st.st_size != op.expected_size:
            return Result(op_id=op.op_id, ok=False, status="STALE",
                          error_code=E_SRC_SIZE_CHANGED,
                          error_message=f"src size changed: expected={op.expected_size} actual={st.st_size} src={src_abs}")

        # mtime mismatch: strict -> STALE, else allow (hash check will decide)
        if op.expected_mtime and int(st.st_mtime) != op.expected_mtime:
            if strict_mtime:
                return Result(op_id=op.op_id, ok=False, status="STALE",
                              error_code=E_SRC_MTIME_CHANGED,
                              error_message=f"src mtime changed: expected={op.expected_mtime} actual={int(st.st_mtime)} src={src_abs}")

        # Idempotent dest exists?
        if dest_abs.exists():
            dst_st = dest_abs.stat()
            if op.expected_size and dst_st.st_size != op.expected_size:
                return Result(op_id=op.op_id, ok=False, status="ERROR",
                              error_code=E_DEST_EXISTS_MISMATCH,
                              error_message=f"dest exists size mismatch: dest={dest_abs} size={dst_st.st_size} expected={op.expected_size}")
            if verify_existing:
                computed = compute_sha256(dest_abs)
                if computed.lower() != op.sha256.lower():
                    return Result(op_id=op.op_id, ok=False, status="ERROR",
                                  error_code=E_HASH_MISMATCH,
                                  error_message=f"existing dest hash mismatch: dest={dest_abs} computed={computed} expected={op.sha256}")
                return Result(op_id=op.op_id, ok=True, status="DONE", bytes_copied=0, verified=1)
            return Result(op_id=op.op_id, ok=True, status="DONE", bytes_copied=0, verified=0)

        # Ensure parent dirs
        dest_parent.mkdir(parents=True, exist_ok=True)

        # Cleanup leftover temp for this op
        cleanup_tmp_prefix(dest_parent, op.op_id)

        # Copy to tmp
        tmp_name = f".__tmpcopy__.op{op.op_id}.{int(time.time()*1000)}"
        tmp_path = dest_parent / tmp_name

        try:
            ok, bytes_written, computed = stream_copy_with_sha256(src_abs, tmp_path, expected_sha256=op.sha256)
        except FileExistsError:
            # extremely unlikely; try another name
            tmp_path = dest_parent / f".__tmpcopy__.op{op.op_id}.{int(time.time()*1000)}.{os.getpid()}"
            ok, bytes_written, computed = stream_copy_with_sha256(src_abs, tmp_path, expected_sha256=op.sha256)

        if not ok:
            # Remove temp (do not leave garbage)
            try:
                if tmp_path.exists():
                    tmp_path.unlink()
            except Exception:
                pass
            return Result(op_id=op.op_id, ok=False, status="STALE",
                          error_code=E_HASH_MISMATCH,
                          error_message=f"hash mismatch after copy: computed={computed} expected={op.sha256} src={src_abs}")

        # Atomic finalize
        os.replace(str(tmp_path), str(dest_abs))

        return Result(op_id=op.op_id, ok=True, status="DONE", bytes_copied=bytes_written, verified=1)

    except OSError as e:
        code = E_IO_ERROR
        if e.errno == errno.ENOSPC:
            code = E_DISK_FULL
        elif e.errno in (errno.EACCES, errno.EPERM):
            code = E_PERMISSION_DENIED
        return Result(op_id=op.op_id, ok=False, status="ERROR", error_code=code, error_message=str(e))
    except ValueError as e:
        return Result(op_id=op.op_id, ok=False, status="ERROR", error_code=E_PLAN_INVALID, error_message=str(e))
    except KeyboardInterrupt:
        _STOP_EVENT.set()
        return Result(op_id=op.op_id, ok=False, status="ERROR", error_code=E_UNKNOWN, error_message="interrupted")
    except Exception as e:
        return Result(op_id=op.op_id, ok=False, status="ERROR", error_code=E_UNKNOWN, error_message=str(e))


def worker_loop(task_q: "queue.Queue[Tuple[Op,str,Path,bool,bool]]",
                result_q: "queue.Queue[Result]") -> None:
    while not _STOP_EVENT.is_set():
        try:
            op, src_mount, dest_root_abs, strict_mtime, verify_existing = task_q.get(timeout=0.25)
        except queue.Empty:
            continue
        try:
            res = copy_one(op, src_mount, dest_root_abs, strict_mtime=strict_mtime, verify_existing=verify_existing)
            result_q.put(res)
        finally:
            task_q.task_done()


def cmd_validate(db: Path) -> int:
    con = connect_db(db)
    plan = load_plan(con)
    problems = validate_plan(con, plan)
    if problems:
        print("PLAN INVALID:")
        for p in problems:
            print(f"- {p}")
        return EXIT_PLAN_INVALID

    # dest mount check
    mp = mount_point_for_volume_uuid(plan.dest_volume_uuid)
    if not mp:
        print(f"DEST volume not mounted or not found: {plan.dest_volume_uuid}")
        return EXIT_PLAN_INVALID

    dest_root_abs = (Path(mp) / plan.dest_root_relpath).resolve()
    print("OK")
    print(f"dest_mount_point: {mp}")
    print(f"dest_root_abs:    {dest_root_abs}")
    # Basic relpath safety check sample
    bad = con.execute("SELECT COUNT(*) AS n FROM ops WHERE op_type='COPY' AND (dest_rel_path LIKE '/%' OR dest_rel_path LIKE '%..%')").fetchone()
    if bad and int(bad["n"]) > 0:
        print(f"WARN: potentially unsafe dest_rel_path rows: {bad['n']}")
    return EXIT_OK


def cmd_status(db: Path) -> int:
    con = connect_db(db)
    rows = con.execute("SELECT status, COUNT(*) AS n FROM ops GROUP BY status ORDER BY status").fetchall()
    for r in rows:
        print(f"{r['status']}\t{r['n']}")
    return EXIT_OK


def acquire_lock(db: Path) -> Optional[Path]:
    lock_path = db.with_suffix(db.suffix + ".lock")
    try:
        fd = os.open(str(lock_path), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o644)
        with os.fdopen(fd, "w") as f:
            f.write(f"pid={os.getpid()}\n")
            f.write(f"ts={time.time()}\n")
        return lock_path
    except FileExistsError:
        return None


def release_lock(lock_path: Path) -> None:
    try:
        lock_path.unlink()
    except Exception:
        pass


def cmd_run(db: Path,
            workers: int,
            retry_errors: bool,
            reset_running_flag: bool,
            strict_mtime: bool,
            verify_existing_mode: str,
            dry_run: bool) -> int:

    _install_signal_handlers()

    con = connect_db(db)
    plan = load_plan(con)
    problems = validate_plan(con, plan)
    if problems:
        for p in problems:
            print(f"PLAN INVALID: {p}", file=sys.stderr)
        return EXIT_PLAN_INVALID

    # lock (avoid concurrent executors)
    if not dry_run:
        lock = acquire_lock(db)
        if not lock:
            print(f"Another executor seems running (lock exists): {db.with_suffix(db.suffix + '.lock')}", file=sys.stderr)
            return EXIT_PLAN_INVALID
    else:
        lock = None

    try:
        if reset_running_flag:
            n = reset_running(con)
            print(f"reset RUNNING -> PENDING: {n}")

        dest_mount = mount_point_for_volume_uuid(plan.dest_volume_uuid)
        if not dest_mount:
            print(f"DEST volume not mounted or not found: {plan.dest_volume_uuid}", file=sys.stderr)
            return EXIT_PLAN_INVALID

        dest_root_abs = (Path(dest_mount) / plan.dest_root_relpath).resolve()
        if not dry_run:
            dest_root_abs.mkdir(parents=True, exist_ok=True)

        # Verify-existing option
        verify_existing = (verify_existing_mode.lower() == "sha256")

        # Cache src mounts for UUIDs referenced by candidate ops
        uuid_rows = con.execute(
            """
            SELECT DISTINCT src_volume_uuid
            FROM ops
            WHERE op_type='COPY' AND status IN ('PENDING','ERROR')
            """
        ).fetchall()
        src_mounts: Dict[str, str] = {}
        for r in uuid_rows:
            vu = (r["src_volume_uuid"] or "").strip()
            if not vu:
                continue
            mp = mount_point_for_volume_uuid(vu)
            if mp:
                src_mounts[vu] = mp

        task_q: "queue.Queue[Tuple[Op,str,Path,bool,bool]]" = queue.Queue(maxsize=max(100, workers * 10))
        result_q: "queue.Queue[Result]" = queue.Queue()

        threads = []
        for _ in range(max(1, workers)):
            t = threading.Thread(target=worker_loop, args=(task_q, result_q), daemon=True)
            t.start()
            threads.append(t)

        in_flight = 0
        any_error = False

        def has_more_ops() -> bool:
            # quick check for remaining ops
            statuses = ("PENDING",) if not retry_errors else ("PENDING","ERROR")
            qmarks = ",".join(["?"]*len(statuses))
            row = con.execute(
                f"SELECT 1 FROM ops WHERE op_type='COPY' AND status IN ({qmarks}) LIMIT 1",
                statuses
            ).fetchone()
            return row is not None

        while not _STOP_EVENT.is_set():
            # Feed tasks
            while not _STOP_EVENT.is_set() and in_flight < workers * 4 and not task_q.full():
                op = select_one_op(con, retry_errors=retry_errors)
                if not op:
                    break

                # Safety: dest_rel_path must be safe
                if not is_safe_relpath(op.dest_rel_path):
                    res = Result(op_id=op.op_id, ok=False, status="ERROR",
                                 error_code=E_PLAN_INVALID,
                                 error_message=f"unsafe dest_rel_path: {op.dest_rel_path!r}")
                    update_result(con, res, dry_run=dry_run)
                    any_error = True
                    continue

                # Resolve src mount
                src_mount = src_mounts.get(op.src_volume_uuid)
                if not src_mount:
                    # immediate error
                    res = Result(op_id=op.op_id, ok=False, status="ERROR",
                                 error_code=E_SRC_VOLUME_MISSING,
                                 error_message=f"src volume not mounted: {op.src_volume_uuid}")
                    # mark attempt? only if not dry_run
                    mark_running(con, op.op_id, dry_run=dry_run)
                    update_result(con, res, dry_run=dry_run)
                    any_error = True
                    continue

                if dry_run:
                    print(f"DRYRUN op_id={op.op_id} src={src_mount}/{op.src_rel_path} -> dest={dest_root_abs}/{op.dest_rel_path}")
                    # do not mark running or enqueue
                    # mark as skipped? no, dry run should not mutate.
                    continue

                mark_running(con, op.op_id, dry_run=dry_run)
                task_q.put((op, src_mount, dest_root_abs, strict_mtime, verify_existing))
                in_flight += 1

            # Drain results
            try:
                res = result_q.get(timeout=0.25)
            except queue.Empty:
                if dry_run:
                    break
                if in_flight == 0 and not has_more_ops():
                    break
                continue

            update_result(con, res, dry_run=dry_run)
            if not res.ok:
                any_error = True
            in_flight = max(0, in_flight - 1)

        if _STOP_EVENT.is_set():
            return EXIT_INTERRUPTED

        if dry_run:
            return EXIT_OK

        return EXIT_PARTIAL_ERROR if any_error else EXIT_OK

    finally:
        if lock is not None:
            release_lock(lock)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="executor")
    sub = p.add_subparsers(dest="cmd", required=True)

    p_val = sub.add_parser("validate")
    p_val.add_argument("--db", required=True)

    p_stat = sub.add_parser("status")
    p_stat.add_argument("--db", required=True)

    p_run = sub.add_parser("run")
    p_run.add_argument("--db", required=True)
    p_run.add_argument("--workers", type=int, default=2)
    p_run.add_argument("--retry-errors", action="store_true")
    p_run.add_argument("--reset-running", action="store_true")
    p_run.add_argument("--strict-mtime", action="store_true")
    p_run.add_argument("--verify-existing", choices=["none","sha256"], default="none")
    p_run.add_argument("--dry-run", action="store_true")

    return p


def main(argv: List[str]) -> int:
    args = build_parser().parse_args(argv)
    db = Path(args.db).expanduser()

    if args.cmd == "validate":
        return cmd_validate(db)
    if args.cmd == "status":
        return cmd_status(db)
    if args.cmd == "run":
        return cmd_run(
            db=db,
            workers=max(1, args.workers),
            retry_errors=bool(args.retry_errors),
            reset_running_flag=bool(args.reset_running),
            strict_mtime=bool(args.strict_mtime),
            verify_existing_mode=str(args.verify_existing),
            dry_run=bool(args.dry_run),
        )
    return EXIT_FATAL


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
