# Photo Archive Planner (Phase 1 / Phase 2) - v2

目的: macOS上で、Photos/iPhotoライブラリや任意フォルダに散在する「**オリジナル実体ファイル**」だけを抽出し、
**ディスク上のファイル名を変更せず**に、重複（同一SHA-256）を削減したファイルアーカイブを作る。

- **Phase 1 (UI/Planner)**: ソースをスキャン → SHA-256算出 → 重複特定 → **実行計画(DB)** を確定・凍結
- **Phase 2 (Executor Script)**: Phase 1のDBを読み、計画に従って **COPY** を実行（MOVEは禁止）

## 出力アーカイブの物理配置（要件反映）
- ファイル名はそのまま保持
- 同一SHA-256は1つだけ残す
- ルートは日付階層 `YYYY/MM/DD` を作る

### 推奨レイアウト
衝突（同日・同名ファイル）を避けるため、日付配下に **SHA-256フォルダ** を挟む。

```
DEST_ROOT/
  YYYY/
    MM/
      DD/
        <full_sha256>/
          <original_filename.ext>
```

- `<original_filename.ext>` は **ソース上のディスク名を保持**
- `<full_sha256>` はコンテンツSHA-256（同一内容は同一フォルダへ集約）
- 同一sha256は1つだけ保存（duplicatesはDBに残るが物理的には増やさない）

## “生成ファイルを入れない”ポリシー
- DEST_ROOT には **実体ファイルのみ** を置く
- DB/ログは **アプリ側のApplication Support** に置くのが推奨（DESTを汚さない）
  - ただしDBはアーカイブと同等に重要なので別途バックアップ対象

各フェーズの詳細は `phase1/PHASE1_SPEC.md` と `phase2/PHASE2_SPEC.md` を参照。


## タイムゾーン方針
- フォールバックで mtime を使う場合の `YYYY/MM/DD` は **UTC固定** で算出します（再現性優先）。


## 更新
- Phase 2 仕様を確定版に更新（v5）。
