# PhotoArchivePlanner UI (SwiftUI / macOS)

このフォルダは、あなたが設計した **Phase 1（UIで計画DB作成）→ Phase 2（別スクリプトでCOPY実行）** を前提にした
macOS SwiftUI アプリのUI雛形です。

## 何ができるか（MVP）
- 様々なバージョンのライブラリ（`.photoslibrary` / `.photolibrary`）とフォルダを **ドラッグ&ドロップ**で追加
- 出力先（DESTフォルダ）を **ドラッグ&ドロップ**またはボタンで選択
- “Plan DB（SQLite）作成（Phase 1）” を開始（バックグラウンドで動く）
- 進捗（ステージ、処理中ファイル、件数/バイト）とログを表示
- Plan DB（FROZEN）を生成（Phase 2 executor.py が読む想定）

## 重要: Sandbox と権限
外付けドライブやPhotosライブラリ等へ広範囲にアクセスするため、開発時は以下が楽です。

- App Sandbox を **OFF**（Xcode: Signing & Capabilities）
- もしくは ON の場合は、ユーザー選択（NSOpenPanel）で Security-Scoped Bookmark を実装する必要があります
（ドラッグ&ドロップだけで全権限を得るのは難しい）。

## セットアップ手順（推奨）
1. Xcode で macOS App (SwiftUI) を新規作成（例: `PhotoArchivePlanner`）
2. この `Sources/` 内の `.swift` ファイルをプロジェクトへ追加
3. `Link Binary With Libraries` に `libsqlite3.tbd` を追加（SQLite3 を使うため）
4. 実行

> 既存の Phase 2 スクリプト（Python executor）は別途同梱していません。
> 生成された plan.sqlite を Phase 2 側で実行してください。

## レイアウト要件
- 出力先は `DEST/YYYY/MM/DD/<sha256>/<filename>`（ファイル名は変更しない）
- 同一 sha256 は 1つだけ残す
- mtimeフォールバックの日付は **UTC固定**

詳細: `Docs/` を参照。
