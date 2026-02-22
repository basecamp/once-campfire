# 技術スタックと構成

## 技術スタック

### バックエンド

- Ruby `3.4.5`（`.ruby-version`）
- Rails `8.2`（`config/application.rb`）
- Puma（アプリサーバー）
- Resque / `resque-pool`（非同期ジョブ）
- Action Cable（リアルタイム通信）
- Jbuilder（JSON レスポンス）

### フロントエンド

- Propshaft（アセット）
- Importmap（JS 依存管理）
- Hotwire（Turbo + Stimulus）
- Action Text + Trix（リッチテキスト）

### データ・外部サービス

- SQLite（`config/database.yml`）
- Redis（キャッシュ、Action Cable、ジョブ関連）
- Active Storage（ローカルディスク）
- Sentry（任意）

### ミドルウェア・ランタイム

- `Rack::Deflater`（レスポンス圧縮）
- `ActionDispatch::DebugLocks`（開発時デバッグ用）
- `thrust` 経由で Web プロセスを起動

## ディレクトリ構成

- `app/`: Rails アプリ本体（MVC、ジョブ、チャネル、ビュー、アセット）
- `app/javascript/`: Stimulus コントローラや初期化処理などのフロントエンド実装
- `bin/`: 開発・起動・運用用スクリプト
- `config/`: 環境設定、初期化、ルーティング、DB/Redis 設定
- `db/`: マイグレーションと DB 関連ファイル
- `lib/`: アプリ共通ライブラリ、拡張コード
- `public/`: 静的配信ファイル
- `script/`: 管理・開発補助スクリプト
- `test/`: 単体・結合・システムテスト
- `tmp/`: 実行時の一時ファイル
- `storage/`: SQLite ファイルや Active Storage データの保存先
- `vendor/`: ベンダリング済み依存物

## プロセス構成（ローカル）

`bin/boot` + `Procfile` で以下を並行起動します。

- `web`: Rails アプリ本体
- `redis`: Redis サーバー
- `workers`: Resque ワーカー群
