# ローカル開発環境セットアップ

## 前提

- macOS または Linux
- Docker（`bin/setup` で Redis を自動起動するため推奨）またはローカル Redis
- Homebrew / pacman / apt のいずれか

## 初回セットアップ

```bash
bin/setup
```

`bin/setup` で以下を実行します。

- 依存パッケージのインストール（環境に応じて）
- Ruby / gem のセットアップ
- DB 準備（`rails db:prepare`）
- Redis 起動確認と必要時の起動
- ログと一時ファイルのクリーンアップ

## 起動方法

Web アプリだけを起動する場合:

```bash
bin/dev
```

Web + Redis + ワーカーをまとめて起動する場合:

```bash
bin/boot
```

`bin/boot` は `Procfile` を使って次を起動します。

- `web`: `bundle exec thrust bin/start-app`
- `redis`: `redis-server config/redis.conf`
- `workers`: `FORK_PER_JOB=false INTERVAL=0.1 bundle exec resque-pool`

## アクセス

- ブラウザで [http://localhost:3000](http://localhost:3000) を開きます。
- 初回ログイン前に管理者アカウント作成フローへ進みます。

## Docker 実行（参考）

```bash
docker build -t campfire .

docker run \
  --publish 80:80 --publish 443:443 \
  --restart unless-stopped \
  --volume campfire:/rails/storage \
  --env SECRET_KEY_BASE=$YOUR_SECRET_KEY_BASE \
  --env VAPID_PUBLIC_KEY=$YOUR_PUBLIC_KEY \
  --env VAPID_PRIVATE_KEY=$YOUR_PRIVATE_KEY \
  --env TLS_DOMAIN=chat.example.com \
  campfire
```

主要な環境変数:

- `TLS_DOMAIN`: Let's Encrypt で TLS を有効化
- `DISABLE_SSL`: TLS を無効化して HTTP 配信
- `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY`: Web Push 用鍵
- `SENTRY_DSN`: Sentry エラー通知
