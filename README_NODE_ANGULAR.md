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
- Boosts
- Search
- Webhooks
- Presence / Read / Unread / Typing
- Push subscriptions + Web Push dispatch
- Bot webhook jobs
- Remove banned content job
- Moderation ban/unban

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
