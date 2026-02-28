# MIGRATION_NODE_ANGULAR

## Цель

Перенос серверной и клиентской части Campfire с Rails на:

- Backend: `Node.js + Fastify + TypeScript + MongoDB + Redis`
- Frontend: `Angular 20+`

## Что перенесено по серверным блокам

### 1) Direct rooms

- Singleton direct-room через `directKey` в модели room.
- Создание/поиск direct room: `POST /api/v1/rooms/directs`.
- В direct membership по умолчанию `everything`.

Ключевые файлы:

- `apps/api/src/models/room.model.ts`
- `apps/api/src/routes/rooms.route.ts`

### 2) Boosts / Search / Webhooks

- Boosts:
  - `GET /api/v1/messages/:messageId/boosts`
  - `POST /api/v1/messages/:messageId/boosts`
  - `DELETE /api/v1/messages/:messageId/boosts/:boostId`
- Search:
  - `GET /api/v1/searches`
  - `POST /api/v1/searches`
  - `DELETE /api/v1/searches/clear`
- Webhooks:
  - `GET /api/v1/webhooks`
  - `POST /api/v1/webhooks`
  - `DELETE /api/v1/webhooks/:webhookId`
  - `POST /api/v1/webhooks/:webhookId/test`

Ключевые файлы:

- `apps/api/src/routes/messages.route.ts`
- `apps/api/src/routes/searches.route.ts`
- `apps/api/src/routes/webhooks.route.ts`
- `apps/api/src/models/boost.model.ts`
- `apps/api/src/models/search.model.ts`
- `apps/api/src/models/webhook.model.ts`

### 3) Realtime (SSE) + Presence/Read/Unread/Typing

- SSE stream: `GET /api/v1/realtime/stream`
- Presence:
  - `POST /api/v1/realtime/rooms/:roomId/presence/present`
  - `POST /api/v1/realtime/rooms/:roomId/presence/absent`
  - `POST /api/v1/realtime/rooms/:roomId/presence/refresh`
- Typing:
  - `POST /api/v1/realtime/rooms/:roomId/typing/start`
  - `POST /api/v1/realtime/rooms/:roomId/typing/stop`

События realtime:

- `room.created`
- `message.created`
- `message.boosted`
- `message.removed`
- `room.unread`
- `room.read`
- `typing.start`
- `typing.stop`

Ключевые файлы:

- `apps/api/src/routes/realtime.route.ts`
- `apps/api/src/realtime/event-bus.ts`
- `apps/api/src/realtime/redis-realtime.ts`
- `apps/api/src/services/membership-connection.ts`

### 4) Redis parity blocks (очереди и фоновые jobs)

#### Webhook queue

- BullMQ очередь для webhook dispatch:
  - `apps/api/src/queues/webhook.queue.ts`

#### PushMessage job (аналог Room::PushMessageJob)

- Очередь:
  - `apps/api/src/queues/push-message.queue.ts`
- Web Push sender:
  - `apps/api/src/services/push-notifications.ts`
- Push subscriptions model:
  - `apps/api/src/models/push-subscription.model.ts`

#### Bot Webhook job (аналог Bot::WebhookJob)

- Очередь:
  - `apps/api/src/queues/bot-webhook.queue.ts`
- Диспетчер ботов по правилам:
  - direct-room: все bot users в direct кроме автора
  - shared-room: только упомянутые bots
- Файл:
  - `apps/api/src/services/bot-dispatch.ts`

#### RemoveBannedContent job (аналог RemoveBannedContentJob)

- Очередь:
  - `apps/api/src/queues/moderation.queue.ts`
- Событие удаления сообщения в realtime (`message.removed`).

### 5) Moderation / Bans

- Session model для IP/user-agent активности.
- Ban model.
- Маршруты:
  - `POST /api/v1/users/:userId/ban`
  - `DELETE /api/v1/users/:userId/ban`

На ban:

- собираются IP из сессий пользователя;
- пользователь получает статус `banned`;
- сессии удаляются;
- запускается job удаления контента.

Ключевые файлы:

- `apps/api/src/models/session.model.ts`
- `apps/api/src/models/ban.model.ts`
- `apps/api/src/routes/moderation.route.ts`

### 6) Push subscriptions API

- `GET /api/v1/users/me/push-subscriptions`
- `POST /api/v1/users/me/push-subscriptions`
- `DELETE /api/v1/users/me/push-subscriptions/:subscriptionId`
- `POST /api/v1/users/me/push-subscriptions/:subscriptionId/test`

Файл:

- `apps/api/src/routes/push-subscriptions.route.ts`

## Auth/session parity additions

- JWT теперь несёт `sid`, проверяется активная session запись.
- `logout` удаляет session запись.

Файлы:

- `apps/api/src/plugins/auth.ts`
- `apps/api/src/routes/auth.route.ts`
- `apps/api/src/services/session-auth.ts`

## Конфигурация окружения

В `.env` для API требуются:

- `MONGODB_URI`
- `REDIS_URL`
- `REDIS_PREFIX`
- `APP_BASE_URL`
- `VAPID_PUBLIC_KEY`
- `VAPID_PRIVATE_KEY`
- `VAPID_SUBJECT`
- `JWT_SECRET`

Файлы:

- `apps/api/.env.example`
- `apps/api/src/config/env.ts`

## Инфраструктура

- `docker-compose.node.yml` поднимает:
  - `mongodb`
  - `redis`

## Проверки

Успешно выполнены:

- `cd apps/api && npm run lint`
- `cd apps/api && npm run build`
- `cd apps/web && npm run build`

