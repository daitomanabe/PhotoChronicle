# UI 仕様（Phase 1 Planner UI）

## 画面構成（提案）
左: Sources
- Libraries（.photoslibrary / .photolibrary）
- Folders（任意フォルダ）
- D&D で追加、重複パスは除外、削除ボタン

右: Plan / Destination
- DEST フォルダ指定（D&D / 選択）
- Plan DB 保存先（デフォルト: Application Support）
- Start（Phase 1 実行）
- Cancel

下: Progress / Log
- Stage（Scanning / Hashing / Building blobs / Freezing）
- Current file
- counts / bytes
- ログ

## Phase 1 エンジン連携
このUI雛形は `PlannerEngine` を呼び出し、SQLite plan を生成します。
現状は “実務に耐える最低限の実装” まで入っていますが、12TB運用は環境差が大きいので、
ワーカー数や除外パターン、スキャンルート（Photos Libraryの Originals/Masters 判定）等は調整してください。

