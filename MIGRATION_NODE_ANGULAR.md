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
  - parity details:
    - query normalization (Rails-like sanitize)
    - history dedupe + `top 10` recent queries
    - results page-size parity (`up to 100`)
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
- `room.removed`
- `message.created`
- `message.updated`
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
- Timeout fallback:
  - при истечении 7 секунд бот отправляет сообщение `"Failed to respond within 7 seconds"` (аналог Rails fallback).
- Attachment response parity:
  - если webhook бота отвечает бинарным контентом (не `text/plain|text/html`), создаётся message с `attachment`.
  - attachment доступен через `GET /api/v1/messages/:messageId/attachment`.

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
- Rails-compatible aliases:
  - `GET /api/v1/users/:userId/push_subscriptions`
  - `POST /api/v1/users/:userId/push_subscriptions`
  - `DELETE /api/v1/users/:userId/push_subscriptions/:id`
  - `POST /api/v1/users/:userId/push_subscriptions/:push_subscription_id/test_notifications`
- Поддерживаются camelCase и snake_case payload keys:
  - `p256dhKey` / `p256dh_key`
  - `authKey` / `auth_key`
  - nested `push_subscription`.

Файл:

- `apps/api/src/routes/push-subscriptions.route.ts`

## Auth/session parity additions

- JWT теперь несёт `sid`, проверяется активная session запись.
- `logout` удаляет session запись.

Файлы:

- `apps/api/src/plugins/auth.ts`
- `apps/api/src/routes/auth.route.ts`
- `apps/api/src/services/session-auth.ts`

## Дополнительно перенесено в текущем проходе

### Message lifecycle parity

- `GET /api/v1/rooms/:roomId/messages` c `before`/`after` pagination (page size 40).
- `GET /api/v1/rooms/:roomId/messages/:messageId`.
- `PATCH|PUT /api/v1/rooms/:roomId/messages/:messageId`.
- `DELETE /api/v1/rooms/:roomId/messages/:messageId`.
- `GET /api/v1/rooms/:roomId/refresh` ограничен до Rails page-size семантики (`new_messages` / `updated_messages`).
- `POST /api/v1/rooms/:roomId/messages` и `POST /api/v1/rooms/:roomId/:botKey/messages` теперь поддерживают:
  - `multipart/form-data` attachment (`attachment` field)
  - text body + attachment
  - raw binary body для bot endpoint (вложение без multipart)

### Rooms parity additions

- `GET /api/v1/rooms/:roomId/settings`.
- `DELETE /api/v1/rooms/:roomId` с broadcast `room.removed`.
- `POST /api/v1/rooms/directs` теперь поддерживает:
  - `userId`
  - `userIds`
  - `user_ids`
  - singleton-key direct room для полного набора участников.

### Missing Rails endpoints added

- `GET /api/v1/first_run`
- `POST /api/v1/first_run`
- `POST /api/v1/unfurl_link`
- `GET|PATCH /api/v1/account`
- `GET|PATCH|DELETE /api/v1/account/users/:id`
- `GET|POST|PATCH|DELETE /api/v1/account/bots/:id`
- `PATCH /api/v1/account/bots/:botId/key`
- `POST /api/v1/account/join_code`
- `GET|DELETE /api/v1/account/logo`
- `GET|PATCH /api/v1/account/custom_styles` + `GET /api/v1/account/custom_styles/edit`
- `GET|POST /api/v1/join/:joinCode`
- `GET|PATCH /api/v1/session/transfers/:id`
- `GET /api/v1/autocompletable/users`
- `GET /api/v1/users/:id`
- `GET|PATCH /api/v1/users/me/profile`
- `GET /api/v1/users/me/sidebar`
- `GET|DELETE /api/v1/users/:userId/avatar`
- `GET /api/v1/rooms/:roomId`
- `GET /api/v1/rooms/:roomId/@:messageId`
- `POST /api/v1/rooms/opens`
- `PATCH /api/v1/rooms/opens/:id`
- `POST /api/v1/rooms/closeds`
- `PATCH /api/v1/rooms/closeds/:id`
- `GET /api/v1/session/new`
- `POST|DELETE /api/v1/session`
- `GET /api/v1/qr_code/:id`
- `GET /api/v1/webmanifest`
- `GET /api/v1/service-worker`

### Security/session/realtime parity additions

- Signed transfer flow:
  - `/session/transfers/:id` переведён на signed token verification (purpose `transfer`, TTL 4 часа).
  - `GET /api/v1/users/:id` (для admin) теперь отдает `transfer_id`.
- Realtime forced disconnect:
  - при `ban`, `deactivate`, revoke membership (`PATCH /rooms/closeds/:id`) открытые SSE подключения принудительно закрываются с event `disconnect`.
- Welcome + room visit tracking:
  - `GET /` и `GET /welcome` теперь редиректят аутентифицированного пользователя в последнюю/дефолтную комнату.
  - при `GET /rooms/:roomId` и `GET /rooms/:roomId/@:messageId` сохраняется cookie `last_room`.
- Session create rate-limit:
  - добавлен лимит 10 попыток / 3 минуты на IP для `POST /session`.
- Version headers:
  - ответы API выставляют `X-Version` и `X-Rev`.
- Account logo response:
  - `GET /account/logo` доступен без auth и отдает `logoUrl` redirect или stock PNG fallback (вместо JSON-only контракта).
- Unfurl safety guards:
  - public-IP resolution check before outbound fetch
  - redirect limit (`<=10`)
  - HTML body size limit (`<=5MB`)
  - media/file URL deny-list
- Boost remove realtime:
  - `DELETE /messages/:messageId/boosts/:boostId` публикует realtime remove event (`message.boost_removed`).

### Финальные parity-блоки (закрытие 100% server checklist)

- `Room::PushMessageJob` parity:
  - refined mention extraction (`html/rich-text data-user-id`, `/users/:id` links, `@name` fallback);
  - involvement parity: `everything` + `mentions` only when mentionee matched;
  - push icon parity: `/account/logo`.
- Browser/platform middleware parity:
  - глобальный `AllowBrowser` эквивалент (min versions: Safari 17.2, Chrome 120, Firefox 121, Opera 104, IE blocked);
  - `SetPlatform` эквивалент через request platform context;
  - HTML fallback `sessions/incompatible_browser` на неподдерживаемых браузерах.
- Avatar/logo ActiveStorage-like parity:
  - хранение binary-attachment в Mongo (`user.avatar`, `account.logo`);
  - signed avatar token URLs (`/users/:signed_id/avatar?v=...`);
  - cache behavior parity (`users/avatar`: 30m SWR, `account/logo`: 5m SWR);
  - variant rendering parity:
    - `users/avatar` -> `webp 512` (через `sharp`);
    - `account/logo` -> `png 192/512` (через `sharp`);
  - multipart upload parity:
    - `PATCH /account` (`account[logo]`)
    - `PATCH /users/me/profile` (`user[avatar]`)
    - `POST /join/:joinCode` (`user[avatar]`)
    - `POST /first_run` (`user[avatar]`)
    - `POST|PATCH /account/bots/:id` (`user[avatar]`)

### Rails path compatibility aliases (без `/api/v1`)

- Добавлены alias-регистрации маршрутов для Rails-путей:
  - `/rooms/*`, `/messages/*`, `/searches/*`, `/users/*`, `/account/*`, `/join/*`, `/session/*`, `/qr_code/*`, `/webmanifest`, `/service-worker`, `/up`, `/`.
- Это позволяет сохранить обратную совместимость с Rails URL-контрактом параллельно с `/api/v1/*`.

Ключевые файлы:

- `apps/api/src/routes/rooms.route.ts`
- `apps/api/src/routes/first-run.route.ts`
- `apps/api/src/routes/unfurl-link.route.ts`
- `apps/api/src/routes/account.route.ts`
- `apps/api/src/routes/users.route.ts`
- `apps/api/src/routes/join.route.ts`
- `apps/api/src/routes/session-transfers.route.ts`
- `apps/api/src/routes/autocompletable.route.ts`

## Route parity matrix

- Полная таблица соответствия Rails -> Node: `ROUTE_PARITY_TABLE_FULL.md`.

## Конфигурация окружения

В `.env` для API требуются:

- `MONGODB_URI`
- `REDIS_URL`
- `REDIS_PREFIX`
- `APP_BASE_URL`
- `APP_VERSION`
- `GIT_REVISION`
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
