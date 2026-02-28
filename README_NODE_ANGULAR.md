# README_NODE_ANGULAR

Новый стек расположен рядом с Rails-кодом.

## Компоненты

- API: `apps/api` (`Fastify + MongoDB + Redis`)
- Web: `apps/web` (`Angular 20+`)
- Realtime: SSE (`/api/v1/realtime/stream`)
- Очереди: BullMQ (Redis)
- Compose: `docker-compose.node.yml` (`mongodb`, `redis`)

## Перенесенные серверные блоки

- Direct rooms
- Room settings/involvement/refresh parity
- Message lifecycle parity (`index/show/create/update/destroy`, `before/after`)
- Boosts
- Search
- Webhooks
- Presence / Read / Unread / Typing
- Push subscriptions + Web Push dispatch
- Bot webhook jobs
- Bot webhook attachment replies
- Remove banned content job
- Moderation ban/unban
- First run endpoint
- Unfurl link endpoint
- Account API block (`account/*`)
- Users API block (`users/*`, `join`, `autocompletable`, `session/transfers`)
- Rails path compatibility aliases (маршруты также доступны без `/api/v1`)
- Multipart/binary attachment ingest parity for room/bot message create
- Signed transfer tokens (TTL 4h) + `transfer_id` in user show (admin)
- Realtime forced disconnect on ban/deactivate/membership revoke
- Welcome redirect + `last_room` cookie tracking
- Session create rate-limit parity (10 / 3min)
- `X-Version` / `X-Rev` response headers
- PWA manifest/service-worker parity expansion
- Search history parity (sanitize + dedupe + top10)
- Unfurl SSRF-safe guards (public IP + redirect/body limits)
- Realtime boost-remove event parity
- PushMessage mention/involvement parity (`Room::PushMessageJob` equivalent)
- Browser/platform middleware parity (`AllowBrowser` + `SetPlatform` + incompatible-browser HTML)
- Avatar/logo ActiveStorage-like parity (signed avatar URL + binary storage + png/webp variants)
- Autocomplete parity (`value` + signed `sgid` fields)
- Message attachment parity expansion:
  - preview/thumb endpoints: `GET /messages/:messageId/attachment/preview|thumb`
  - attachment metadata parity (`width/height`, preview flags, download/preview/thumb paths)
- Search parity expansion (`attachment.filename` matching + filename fallback body)
- Ban parity hardening (public-IP only validation/filtering like Rails `Ban#ip_address_is_public`)
- Strict signed avatar token parity (`GET /users/:userId/avatar` accepts signed id only)
- Session HTML parity on Rails aliases (`/session*`, `/session/transfers/*`) with redirect/no-content behavior
- ActionCable-compatible WebSocket endpoint `/cable` (welcome/ping + subscriptions for `Heartbeat`, `UnreadRooms`, `ReadRooms`, `Presence`, `TypingNotifications`)

## Быстрый запуск

1. Поднять инфраструктуру:

```bash
docker compose -f docker-compose.node.yml up -d
```

2. Запустить API:

```bash
cd apps/api
cp .env.example .env
npm install
npm run dev
```

3. Запустить Web:

```bash
cd apps/web
npm install
npm run start
```

4. Открыть:

- `http://localhost:4200`

## Полная детализация

См. `MIGRATION_NODE_ANGULAR.md`.

## Route parity таблица

См. `ROUTE_PARITY_TABLE_FULL.md`.
