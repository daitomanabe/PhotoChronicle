# Phase 2 仕様（確定版）: Executor Script（計画DBに基づくアーカイブ生成）

## 1. 目的
Phase 1 が生成し凍結した SQLite の **実行計画（ops）** を読み取り、オリジナル実体ファイルを DEST に **COPY** してアーカイブを構築する。

あなたの要件（確定）:
- **ファイル名は変更しない**（ディスク上の名前を保持）
- **同一 SHA-256 は 1つだけ残す**（Phase 1 が canonical を決め、Phase 2 は COPY 1件/sha）
- 出力構造は **`DEST_ROOT/YYYY/MM/DD/<sha256>/<filename>`**
  - `YYYY/MM/DD` は Phase 1 が `blobs.archive_date_ymd` を決めて `ops.dest_rel_path` に書き込む
  - Phase 2 は日付計算をしない（レイアウト非依存）
- “生成物は不要”: DEST には **実体ファイルのみ**（副生成物 `._` や sidecar を作らない）
- 安全性: **MOVE（移動）禁止**。元ライブラリは破壊しない（保護目的）

---

## 2. 非目標（Phase 2 でやらないこと）
- Photos/iPhoto DB を読む、ライブラリ構造を解釈する（Phase 1 の責務）
- EXIF の解析（Phase 1 の責務）
- duplicates の別名を物理的に増やす（あなたの要件で不要）
- 元データ削除（別工程）
- DEST の整理/リネーム（不可）

---

## 3. 入出力と契約（DB Contract）

### 3.1 入力
- `plan.sqlite`（Phase 1 が生成）
  - `plan.plan_state = 'FROZEN'` であること（Phase 2 は DRAFT を拒否）
  - `plan.dest_volume_uuid`, `plan.dest_root_relpath` が設定済み
  - `ops` に `op_type='COPY'` が投入済み（1 sha256 につき1件）

### 3.2 出力
- DEST フォルダ配下（外付け新HDD等）にファイルをコピーして構築
- `ops.status` 等を更新（中断復帰/監査のため）
- （任意）`op_events` へログを追加してもよい

### 3.3 Phase 2 が更新してよい DB カラム
- `ops.status`
- `ops.attempt_count`
- `ops.last_error_code / last_error_message`
- `ops.started_at / finished_at`
- `ops.bytes_copied`
- `ops.verified`

※ `files/blobs/file_blob` は **読み取り専用**（計画は凍結済み）。

---

## 4. 実行要件（Safety / Correctness）

### 4.1 不変条件（絶対）
- **上書きしない**  
  `dest_abs_path` が存在する場合:
  - 期待サイズ一致 → DONE 扱い（既存を尊重）
  - サイズ不一致 → ERROR（事故、上書き禁止）
- **原子的に確定する**  
  一時ファイルへコピー → rename/replace で確定（途中停止でも壊れたファイルを本番名で残さない）
- **DEST 配下へは計画されたパス以外に書かない**  
  `dest_rel_path` に `..` や 絶対パスが混入していたら PLAN_INVALID として停止

### 4.2 重要：sha256 ディレクトリ名と内容の一致
出力は `.../<sha256>/<filename>` という構造なので、**書き込む中身がその sha256 と一致しない**とアーカイブが破綻する。

従って Phase 2 は、COPYの結果が想定sha256と一致することを保証する必要がある。
推奨実装（I/Oを増やさない）:
- **コピーしながら SHA-256 を同時に計算**し、expected と一致したときだけ rename で確定する

代替（遅いが単純）:
- OSコピー後に DEST 側の sha256 を再計算して一致確認（12TBではI/Oが増える）

---

## 5. ボリューム解決（マウントポイント変動に耐える）
DBに絶対パスを固定すると、`/Volumes/Drive` → `/Volumes/Drive 1` のような変化で死ぬ。

Phase 2 は以下で解決する:
- `plan.dest_volume_uuid` をキーに、現在マウント中の DEST ボリューム root を解決
- 各 op の `src_volume_uuid` をキーに、現在マウント中の SRC ボリューム root を解決
- `src_abs = src_mount_root + src_rel_path`
- `dest_abs = dest_mount_root + plan.dest_root_relpath + dest_rel_path`

SRC volume が未マウントなら、その op は `SRC_VOLUME_MISSING` として ERROR にする（全体停止は要件次第）。

DEST volume が未マウントなら、実行不能なので即停止（`DEST_VOLUME_MISSING`）。

---

## 6. ステータス遷移（中断復帰）

`ops.status`:
- PENDING: 未処理
- RUNNING: 実行中（クラッシュ時に残り得る）
- DONE: 成功
- ERROR: 失敗（再試行可能）
- STALE: 計画が古い（再計画が必要）※運用で使う場合
- SKIPPED: 明示スキップ（今回の要件では基本不要）

推奨遷移:
- PENDING/ERROR → RUNNING → DONE
- PENDING/ERROR → RUNNING → ERROR/STALE

運用オプション:
- `--reset-running`: RUNNING を PENDING に戻して再開可能にする

---

## 7. CLI 仕様（案）

### 7.1 validate
```
executor validate --db plan.sqlite
```
- plan_state=FROZEN
- dest_volume_uuid が現在マウントされている
- dest_rel_path が相対であり `..` を含まない（パストラバーサル防止）
- ops に COPY が存在する

### 7.2 status
```
executor status --db plan.sqlite
```
- ops の status 集計を表示（DONE/ERROR/PENDING/RUNNING）

### 7.3 run
```
executor run --db plan.sqlite
  [--workers N]                 # 2 推奨（I/O次第で調整）
  [--retry-errors]              # ERROR を再実行対象に含める
  [--reset-running]             # RUNNING を PENDING に戻す
  [--strict-mtime]              # mtime不一致を即STALEにする（デフォルトは size優先）
  [--verify-existing sha256]    # 既存destもsha256検証（I/O増）
  [--dry-run]                   # DB更新せず、実行内容を表示
```

---

## 8. コピー方式（確定）
推奨: **ストリームコピー（in-process） + sha256 同時計算**
- 外部コマンドを大量起動しない（オーバーヘッドを避ける）
- xattr/rsrc/ACL をコピーしない（あなたの要件に一致）
- sha256検証をコピーと同時に行える（I/Oを増やさない）

### 8.1 原子的確定
- `dest_parent` に `.__tmpcopy__.op<op_id>.<timestamp>` を作成
- コピー完了後、sha256一致なら `os.replace(tmp, dest)` で確定
- 一致しない/失敗なら tmp を削除して ERROR/STALE

※ `.tmp` ディレクトリを作らない（DESTに余計なディレクトリを残さない）。

### 8.2 既存 dest の扱い（冪等）
- `dest_abs` が存在し、サイズ一致なら DONE とする（再実行安全）
- サイズ不一致は ERROR（上書き禁止）

---

## 9. エラーコード（DB last_error_code）
- `DEST_VOLUME_MISSING` : 出力ボリュームが未マウント/UUID不一致
- `SRC_VOLUME_MISSING`  : 入力ボリュームが未マウント
- `SRC_NOT_FOUND`       : srcファイルが存在しない
- `SRC_SIZE_CHANGED`    : srcサイズが計画と不一致
- `SRC_MTIME_CHANGED`   : src mtime が計画と不一致（strict時など）
- `HASH_MISMATCH`       : コピーした内容の sha256 が expected と不一致（計画が古い/破損）
- `DEST_EXISTS_MISMATCH`: destが存在するがサイズ不一致（事故）
- `DISK_FULL`           : 空き容量不足
- `PERMISSION_DENIED`   : 権限不足
- `IO_ERROR`            : 読み書きI/Oエラー
- `UNKNOWN`             : その他

---

## 10. 終了コード（プロセス）
- 0: 全対象が DONE（または元から DONE）
- 10: 実行は継続できたが ERROR/STALE が残った
- 20: 計画が不正（FROZENでない/必須情報不足/危険なパス等）
- 30: ユーザー中断（SIGINT/SIGTERM）
- 40: 予期しない例外（バグ）

---

## 11. 推奨運用（現実的な話）
- 出力ディスクは **APFS** 推奨（`._` や互換の問題を避けやすい）
- Phase 2 実行中は、SRC/DEST のマウント解除をしない
- 実行後、必要なら別工程で:
  - `verify`（全件sha256検証）
  - `manifest` 出力（一覧CSV/JSON）
  - 元ライブラリ削除（最後）

