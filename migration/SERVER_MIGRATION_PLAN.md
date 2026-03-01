# План миграции сервера (Rails -> Node.js/Fastify/TypeScript)

## 1. Цель и жесткие ограничения

- Разделить Rails-монолит на отдельный backend и frontend.
- Backend: `Node.js + Fastify + TypeScript + MongoDB + Redis + PM2`.
- JWT проверяется внешним сервисом; в backend подключается только middleware из `https://github.com/meteorhr/middleware`.
- Требование parity: бизнес-логика должна быть 1:1 с текущим Rails.
- Backend отвечает только JSON (без HTML/redirect/render шаблонов).

## 2. Базовые принципы parity

- Сначала фиксируем текущую логику Rails как источник истины:
  - `config/routes.rb`
  - `app/controllers/**`
  - `app/models/**`
  - `app/channels/**`
  - `app/jobs/**`
- Каждый Rails use-case получает эквивалентный Node use-case:
  - те же права доступа;
  - те же side effects (push, webhook, unread/read, membership visibility);
  - те же ограничения (page size, query sanitize, involvement rules, bot behavior).

## 3. Целевая архитектура backend

```text
server/
  src/
    app.ts
    config/
      env.ts
      mongo.ts
      redis.ts
    plugins/
      auth-middleware.ts
      errors.ts
      validation.ts
      rate-limit.ts
    modules/
      rooms/
      messages/
      searches/
      bots/
      push/
      moderation/
      unfurl/
      realtime/
    infra/
      queues/
      pubsub/
      storage/
    shared/
      dto/
      constants/
      utils/
  ecosystem.config.cjs
```

### 3.1. Обязательная структура каждого модуля

Каждый модуль должен иметь единый layout:

```text
src/modules/<module-name>/
  models/
  helpers/
  controllers/
  routes/
```

Это правило применяется ко всем доменам: `account`, `users`, `rooms`, `messages`, `searches`, `bots`, `push`, `moderation`, `unfurl`, `realtime`.

## 4. Контракт аутентификации (внешний JWT middleware)

- Middleware подключается как `onRequest` hook.
- Middleware должен пробрасывать контекст пользователя в `request.session`, минимум:
  - `request.session._id` (userId),
  - `request.session.company` (company/account context, если есть),
  - `request.session.deviceId`.
- API не выпускает JWT и не хранит refresh-поток локально.
- При невалидной сессии backend возвращает только JSON-ошибки:
  - `401 {"error":{"code":"UNAUTHORIZED","message":"..."}}`.

### 4.1. Установка middleware `meteorhr/middleware`

Добавить в проект локальную зависимость:

```json
{
  "dependencies": {
    "auth-jwt": "file:middleware/jwt"
  }
}
```

Источник middleware: `https://github.com/meteorhr/middleware`.

Минимальный setup шагов:

1. Клонировать репозиторий в папку `middleware`.
2. Установить зависимости `middleware/jwt`.
3. Подключить `auth-jwt` как `onRequest` hook в Fastify.
4. Использовать `request.session` и `request.accessToken`, которые проставляет middleware.

## 5. Модель данных (MongoDB) для parity

Коллекции (минимум):

- `accounts`
- `users`
- `rooms` (`type: open|closed|direct`)
- `memberships` (unique: `roomId + userId`)
- `messages`
- `boosts`
- `searches`
- `push_subscriptions`
- `bans`
- `webhooks`

Ключевые индексы:

- `users.email` unique
- `users.botToken` unique sparse
- `memberships.roomId + memberships.userId` unique
- `messages.roomId + messages.createdAt`
- `searches.userId + searches.updatedAt`
- `push_subscriptions.endpoint + p256dhKey + authKey`
- `bans.ipAddress`
- `rooms.directKey` unique (для singleton direct-room)

## 6. Redis зона ответственности

- Realtime pub/sub:
  - unread/read/typing/presence events.
- Очереди задач (BullMQ):
  - bot webhook dispatch;
  - push notifications;
  - remove banned content.
- Rate limit:
  - чувствительные операции (`session-like` операции, brute-force зоны).
- Presence TTL (эквивалент `Membership::Connectable::CONNECTION_TTL`).

### 6.1. Пример конфигов подключения (MongoDB и Redis)

Пример `config/mongodb.js`:

```js
export default {
  pm: 'mongodb+srv://' + process.env.MONGODB_USER + ':' + process.env.MONGODB_PASSWORD + '@cluster0.xfv2hzn.mongodb.net/?retryWrites=true&w=majority&appName=Cluster0',
  ident: 'mongodb+srv://' + process.env.MONGODB_USER + ':' + process.env.MONGODB_PASSWORD + '@cluster0.xfv2hzn.mongodb.net/?retryWrites=true&w=majority'
};
```

Пример `redis-client.js`:

```js
import Redis from 'ioredis';

// Используйте переменные окружения для конфигурации в продакшене
const redis = new Redis({
  host: process.env.REDIS_HOST,
  port: process.env.REDIS_PORT,
  password: process.env.REDIS_PASSWORD,
  maxRetriesPerRequest: 1,
  connectTimeout: 5000,
  enableReadyCheck: false,
  enableOfflineQueue: false
});

redis.on('error', (err) => {
  console.error('Redis connection error:', err);
});

export default redis;
```

## 7. JSON-only API правила

- Никаких `redirect`, `render :template`, HTML-форм.
- Каждый JSON-ответ должен содержать ключ `accessToken` со значением `ctx.accessToken`.
- Единый формат ошибок:

```json
{
  "error": {
    "code": "FORBIDDEN",
    "message": "Not enough permissions",
    "details": null
  }
}
```

Единый формат успешного ответа:

```json
{
  "accessToken": "ctx.accessToken",
  "data": {}
}
```

Если `data` отсутствует (например, `204`), клиент получает заголовки/статус без тела.

- Для бывших binary endpoint-ов (`avatar`, `logo`, `qr`) сервер возвращает JSON-метаданные:
  - URL на файл/variant,
  - contentType,
  - cache metadata.

## 8. Фазы реализации

### Фаза 0. Baseline parity matrix

- Снять полный список Rails endpoint-ов и правил доступа.
- Описать expected side effects для каждого endpoint-а.
- Зафиксировать контрольный dataset и сценарии проверки.

Артефакт: `migration/parity-matrix.md` (рабочий внутренний документ).

### Фаза 1. Каркас сервера

- Поднять Fastify + TypeScript.
- Подключить MongoDB, Redis, structured logging, конфиги окружения.
- Подключить внешний JWT middleware и глобальный error handler.

Критерий готовности: авторизованный `GET /api/v1/health` с `request.session._id`.

### Фаза 2. Доменные модули (без realtime)

- Реализовать REST JSON по доменам:
  - account/users/bots/join-code/custom-styles/logo
  - rooms (open/closed/direct/involvement/settings/refresh)
  - messages + boosts + bot message endpoint
  - searches
  - push subscriptions
  - moderation bans
  - unfurl link

Критерий готовности: parity тесты endpoint-ов проходят.

### Фаза 3. Jobs и async parity

- BullMQ workers:
  - bot webhook logic (timeout fallback, text/binary replies),
  - push dispatch (involvement + mention rules),
  - remove banned content.

Критерий готовности: side effects совпадают с Rails на тестовом наборе.

### Фаза 4. Realtime parity

- Реализовать JSON-события (SSE или WS) с Redis fan-out:
  - `message.created|updated|removed`
  - `room.created|removed|updated`
  - `room.unread|room.read`
  - `typing.start|typing.stop`
  - `presence.present|presence.absent`

Критерий готовности: клиент в real-time видит те же изменения, что и Rails UI.

### Фаза 5. Производственный контур (PM2)

- Разделить процессы:
  - `api` (Fastify)
  - `worker` (BullMQ consumers)
- Подготовить `ecosystem.config.cjs`:
  - restart policy,
  - max memory restart,
  - env разделение (`development/staging/production`).

Базовый шаблон `ecosystem.config.cjs`:

```js
module.exports = {
  apps: [
    {
      name: 'campfire-api',
      script: 'dist/server.js',
      instances: 1,
      exec_mode: 'fork',
      autorestart: true,
      max_memory_restart: '512M',
      env: {
        NODE_ENV: 'production',
        DOMAIN: 'api.meteorhr.com',
        MONGODB_USER: 'ruslankhissamov',
        MONGODB_PASSWORD: '6qEHcxKtouFxceH0',
        REDIS_HOST: 'redis-19573.c11.us-east-1-3.ec2.redns.redis-cloud.com',
        REDIS_PORT: '19573',
        REDIS_PASSWORD: '8mpL7HmjTZVeaT9qTJaOB84rcSOPI2Mc',
        TOKEN_EXPIRATION_MINUTES: 15
      }
    }
  ]
};
```

Критерий готовности: процессная модель стабильно переживает рестарты и деплой.

### Фаза 6. Приемка 100% logic parity

- Контрактные тесты против зафиксированных Rails кейсов.
- Регрессионный checklist по всем доменам.
- Нагрузочная проверка критичных путей:
  - messages create/list/refresh,
  - realtime fan-out,
  - webhook and push queues.

Критерий готовности: нет функциональных расхождений на agreed parity suite.

## 9. Стратегия миграции данных

- Этап A: экспорт из Rails БД в промежуточный JSON snapshot.
- Этап B: трансформация в Mongo-схемы с сохранением id mapping.
- Этап C: валидация связей:
  - user-room-membership,
  - room-message,
  - message-boost,
  - user-push subscriptions.
- Этап D: dry-run миграции + diff отчёт.

## 10. Риски и контроль

- Риск: расхождение прав доступа.
  - Контроль: endpoint-level auth matrix + integration tests.
- Риск: расхождение side effects.
  - Контроль: event snapshot tests (before/after action).
- Риск: гонки refresh/auth middleware.
  - Контроль: централизованный auth adapter и observability.
- Риск: деградация realtime.
  - Контроль: Redis latency SLO + reconnect/backoff policy.

## 11. Definition of Done

- Все бизнес-флоу Rails покрыты JSON endpoint-ами.
- JWT контекст приходит только через внешний middleware.
- API не отдает HTML/redirect.
- Realtime, jobs и moderation parity подтверждены тестами.
- PM2 конфигурация готова для prod и worker separation.

## 12. Route parity table

Источник: `config/routes.rb` + фактические actions в `app/controllers/*`.

Примечание: `bin/rails routes` в текущем окружении не запускается (нет checkout зависимостей Bundler), поэтому таблица составлена по коду маршрутов и контроллеров.

Статусы:
- `DONE` — есть эквивалент в Node API.
- `PARTIAL` — есть часть контракта, но не 1:1.
- `MISSING` — endpoint отсутствует.

| # | Rails | Node | Status | Комментарий |
|---|---|---|---|---|
| 1 | `GET /` (`welcome#show`) | `GET /` | DONE | |
| 2 | `GET /first_run` (`first_runs#show`) | `GET /api/v1/first_run` | DONE | |
| 3 | `POST /first_run` (`first_runs#create`) | `POST /api/v1/first_run` | DONE | |
| 4 | `GET /session/new` (`sessions#new`) | `GET /session/new` | DONE | |
| 5 | `POST /session` (`sessions#create`) | `POST /session` | DONE | |
| 6 | `DELETE /session` (`sessions#destroy`) | `DELETE /session` | DONE | |
| 7 | `GET /session/transfers/:id` (`sessions/transfers#show`) | `GET /api/v1/session/transfers/:id` | DONE | |
| 8 | `PATCH /session/transfers/:id` (`sessions/transfers#update`) | `PATCH /api/v1/session/transfers/:id` | DONE | |
| 9 | `GET /account/edit` (`accounts#edit`) | `GET /account/edit` | DONE | |
| 10 | `PATCH /account` (`accounts#update`) | `PATCH /api/v1/account` | DONE | |
| 11 | `GET /account/users` (`accounts/users#index`) | `GET /api/v1/account/users` | DONE | |
| 12 | `PATCH /account/users/:id` (`accounts/users#update`) | `PATCH /api/v1/account/users/:id` | DONE | |
| 13 | `DELETE /account/users/:id` (`accounts/users#destroy`) | `DELETE /api/v1/account/users/:id` | DONE | |
| 14 | `GET /account/bots` (`accounts/bots#index`) | `GET /api/v1/account/bots` | DONE | |
| 15 | `POST /account/bots` (`accounts/bots#create`) | `POST /api/v1/account/bots` | DONE | |
| 16 | `GET /account/bots/:id/edit` (`accounts/bots#edit`) | `GET /account/bots/:id/edit` | DONE | |
| 17 | `PATCH /account/bots/:id` (`accounts/bots#update`) | `PATCH /api/v1/account/bots/:id` | DONE | |
| 18 | `DELETE /account/bots/:id` (`accounts/bots#destroy`) | `DELETE /api/v1/account/bots/:id` | DONE | |
| 19 | `PATCH /account/bots/:bot_id/key` (`accounts/bots/keys#update`) | `PATCH /api/v1/account/bots/:botId/key` | DONE | |
| 20 | `POST /account/join_code` (`accounts/join_codes#create`) | `POST /api/v1/account/join_code` | DONE | |
| 21 | `GET /account/logo` (`accounts/logos#show`) | `GET /api/v1/account/logo` | DONE | |
| 22 | `DELETE /account/logo` (`accounts/logos#destroy`) | `DELETE /api/v1/account/logo` | DONE | |
| 23 | `GET /account/custom_styles/edit` (`accounts/custom_styles#edit`) | `GET /api/v1/account/custom_styles/edit` | DONE | |
| 24 | `PATCH /account/custom_styles` (`accounts/custom_styles#update`) | `PATCH /api/v1/account/custom_styles` | DONE | |
| 25 | `GET /join/:join_code` (`users#new`) | `GET /api/v1/join/:joinCode` | DONE | |
| 26 | `POST /join/:join_code` (`users#create`) | `POST /api/v1/join/:joinCode` | DONE | |
| 27 | `GET /qr_code/:id` (`qr_code#show`) | `GET /qr_code/:id` | DONE | |
| 28 | `GET /users/:id` (`users#show`) | `GET /api/v1/users/:id` | DONE | |
| 29 | `GET /users/:user_id/avatar` (`users/avatars#show`) | `GET /api/v1/users/:userId/avatar` | DONE | |
| 30 | `DELETE /users/:user_id/avatar` (`users/avatars#destroy`) | `DELETE /api/v1/users/:userId/avatar` | DONE | |
| 31 | `POST /users/:user_id/ban` (`users/bans#create`) | `POST /api/v1/users/:userId/ban` | DONE | |
| 32 | `DELETE /users/:user_id/ban` (`users/bans#destroy`) | `DELETE /api/v1/users/:userId/ban` | DONE | |
| 33 | `GET /users/me/sidebar` (`users/sidebars#show`) | `GET /api/v1/users/me/sidebar` | DONE | |
| 34 | `GET /users/me/profile` (`users/profiles#show`) | `GET /api/v1/users/me/profile` | DONE | |
| 35 | `PATCH /users/me/profile` (`users/profiles#update`) | `PATCH /api/v1/users/me/profile` | DONE | |
| 36 | `GET /users/me/push_subscriptions` (`users/push_subscriptions#index`) | `GET /api/v1/users/:userId/push_subscriptions` | DONE | |
| 37 | `POST /users/me/push_subscriptions` (`users/push_subscriptions#create`) | `POST /api/v1/users/:userId/push_subscriptions` | DONE | |
| 38 | `DELETE /users/me/push_subscriptions/:id` (`users/push_subscriptions#destroy`) | `DELETE /api/v1/users/:userId/push_subscriptions/:id` | DONE | |
| 39 | `POST /users/me/push_subscriptions/:push_subscription_id/test_notifications` (`users/push_subscriptions/test_notifications#create`) | `POST /api/v1/users/:userId/push_subscriptions/:push_subscription_id/test_notifications` | DONE | |
| 40 | `GET /autocompletable/users` (`autocompletable/users#index`) | `GET /api/v1/autocompletable/users` | DONE | |
| 41 | `GET /rooms` (`rooms#index`) | `GET /api/v1/rooms` | DONE | |
| 42 | `POST /rooms` (`rooms#create` via `rooms/opens|closeds` flow in Rails UI) | `POST /rooms` | DONE | |
| 43 | `GET /rooms/:id` (`rooms#show`) | `GET /rooms/:roomId` | DONE | |
| 44 | `DELETE /rooms/:id` (`rooms#destroy`) | `DELETE /api/v1/rooms/:roomId` | DONE | |
| 45 | `GET /rooms/:room_id/messages` (`messages#index`) | `GET /api/v1/rooms/:roomId/messages` | DONE | |
| 46 | `POST /rooms/:room_id/messages` (`messages#create`) | `POST /api/v1/rooms/:roomId/messages` | DONE | |
| 47 | `GET /rooms/:room_id/messages/:id` (`messages#show`) | `GET /api/v1/rooms/:roomId/messages/:messageId` | DONE | |
| 48 | `PATCH /rooms/:room_id/messages/:id` (`messages#update`) | `PATCH /api/v1/rooms/:roomId/messages/:messageId` | DONE | |
| 49 | `DELETE /rooms/:room_id/messages/:id` (`messages#destroy`) | `DELETE /api/v1/rooms/:roomId/messages/:messageId` | DONE | |
| 50 | `POST /rooms/:room_id/:bot_key/messages` (`messages/by_bots#create`) | `POST /api/v1/rooms/:roomId/:botKey/messages` | DONE | |
| 51 | `GET /rooms/:room_id/refresh` (`rooms/refreshes#show`) | `GET /api/v1/rooms/:roomId/refresh` | DONE | |
| 52 | `GET /rooms/:room_id/settings` (`rooms/settings#show`) | `GET /api/v1/rooms/:roomId/settings` | DONE | |
| 53 | `GET /rooms/:room_id/involvement` (`rooms/involvements#show`) | `GET /api/v1/rooms/:roomId/involvement` | DONE | |
| 54 | `PATCH /rooms/:room_id/involvement` (`rooms/involvements#update`) | `PATCH /api/v1/rooms/:roomId/involvement` | DONE | |
| 55 | `GET /rooms/:room_id/@:message_id` (`rooms#show` at_message) | `GET /rooms/:roomId/@:messageId` | DONE | |
| 56 | `POST /rooms/opens` (`rooms/opens#create`) | `POST /rooms/opens` | DONE | |
| 57 | `PATCH /rooms/opens/:id` (`rooms/opens#update`) | `PATCH /rooms/opens/:id` | DONE | |
| 58 | `POST /rooms/closeds` (`rooms/closeds#create`) | `POST /rooms/closeds` | DONE | |
| 59 | `PATCH /rooms/closeds/:id` (`rooms/closeds#update`) | `PATCH /rooms/closeds/:id` | DONE | |
| 60 | `POST /rooms/directs` (`rooms/directs#create`) | `POST /api/v1/rooms/directs` | DONE | |
| 61 | `GET /messages/:message_id/boosts` (`messages/boosts#index`) | `GET /api/v1/messages/:messageId/boosts` | DONE | |
| 62 | `POST /messages/:message_id/boosts` (`messages/boosts#create`) | `POST /api/v1/messages/:messageId/boosts` | DONE | |
| 63 | `DELETE /messages/:message_id/boosts/:id` (`messages/boosts#destroy`) | `DELETE /api/v1/messages/:messageId/boosts/:boostId` | DONE | |
| 64 | `GET /searches` (`searches#index`) | `GET /api/v1/searches` | DONE | |
| 65 | `POST /searches` (`searches#create`) | `POST /api/v1/searches` | DONE | |
| 66 | `DELETE /searches/clear` (`searches#clear`) | `DELETE /api/v1/searches/clear` | DONE | |
| 67 | `POST /unfurl_link` (`unfurl_links#create`) | `POST /api/v1/unfurl_link` | DONE | |
| 68 | `GET /webmanifest` (`pwa#manifest`) | `GET /webmanifest` | DONE | |
| 69 | `GET /service-worker` (`pwa#service_worker`) | `GET /service-worker` | DONE | |
| 70 | `GET /up` (`rails/health#show`) | `GET /up` | DONE | |

## Приоритет закрытия (строго по порядку)

1. Сверить jobs/attachment edge-cases и финализировать parity матрицу.
