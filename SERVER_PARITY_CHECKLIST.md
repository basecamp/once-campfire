# SERVER_PARITY_CHECKLIST

Цель: довести `apps/api` до 100% функционального соответствия серверной части Rails (`app/controllers`, `app/models`, `app/channels`, `app/jobs`, `config/routes.rb`).

## A. Критические расхождения (P0)

- [x] Полный паритет маршрутов Rails -> Node API (включая отсутствующие ресурсы).
- [x] Глобальная блокировка banned IP для небезопасных запросов (аналог `BlockBannedRequests`).
- [x] Полный lifecycle сообщений: create/index/show/update/destroy + paging `before/after`.
- [x] Room refresh endpoint (`since`) с `new_messages` и `updated_messages`.

## B. Realtime parity (P1)

- [x] Эквивалент событий каналов `UnreadRooms`, `ReadRooms`, `Presence`, `Typing`.
- [x] Эквивалент `broadcast_replace`/`broadcast_remove` для message update/delete.
- [x] Эквивалент visibility broadcast при смене involvement (`invisible` <-> visible).

## C. Jobs parity (P1)

- [x] `Room::PushMessageJob` логика полностью эквивалентна (involvement filters, mention rules, direct/shared payload).
- [x] `Bot::WebhookJob` эквивалент (payload, timeout, text response, attachment response).
- [x] `RemoveBannedContentJob` эквивалент (удаление сообщений и realtime remove).

## D. Push/Webhook parity (P1)

- [x] Push subscriptions API контракт совместим с Rails параметрами.
- [x] Webhook delivery поведение эквивалентно Rails (reply parsing, error timeout fallback).
- [x] Bot webhook route parity (`POST /rooms/:room_id/:bot_key/messages`).

## E. Дополнительные серверные endpoints (P2)

- [x] `unfurl_link#create` parity.
- [x] `first_run` parity.
- [x] `rooms/:id/involvement` show/update parity.
- [x] `rooms/:id/settings` parity (минимум эквивалент контрактов).

## F. Валидация и приёмка

- [x] Таблица соответствия Rails route -> Node route с отметкой 100% покрытие.
- [x] Проверка всех очередей/воркеров на startup/shutdown.
- [x] API build/lint green.
- [x] Документация миграции обновлена.

---

## Статус текущего прохода

- [x] Создан чек-лист parity.
- [x] Начат этап закрытия P0.
- [x] Добавлены endpoints: `rooms/:id/settings`, `rooms/:id/messages/:messageId (GET/PATCH/PUT/DELETE)`, `first_run`, `unfurl_link`.
- [x] Добавлена Rails-совместимость для push subscriptions (`push_subscriptions`, snake_case params).
- [x] Обновлён realtime набор событий (`room.removed`, `message.updated`) и ban-guard middleware.
- [x] Добавлен signed transfer flow (`/session/transfers/:id`) с проверкой TTL/подписи и выдачей `transfer_id` в `GET /users/:id` (для admin).
- [x] Добавлен attachment parity для `POST /rooms/:roomId/messages` и `POST /rooms/:roomId/:botKey/messages` (multipart + binary body).
- [x] Добавлен forced realtime disconnect для ban/deactivate/revoked-membership (SSE `disconnect` + close).
- [x] Добавлен `welcome` redirect flow с cookie `last_room` (приближение к `TrackedRoomVisit`).
- [x] Усилен `unfurl_link`: public-IP guard, redirect лимиты, max body size, media/file URL filter.
- [x] Доведён `searches` до Rails-стиля history (`sanitize`, dedupe, top-10 recent).
- [x] Добавлен realtime remove broadcast для `DELETE boosts`.
- [x] Доведён `Room::PushMessageJob`: refined mention extraction (rich-text/html + `@name`), строгие involvement-фильтры, payload/icon parity.
- [x] Добавлен глобальный browser/platform middleware parity (`AllowBrowser`, `SetPlatform`) с HTML-ответом `sessions/incompatible_browser`.
- [x] Доведены `account/logo` и `users/avatar`:
  - signed avatar token URLs (`/users/:signed_id/avatar?v=...`)
  - public avatar/logo delivery + cache headers
  - image variants parity (`logo -> png 192/512`, `avatar -> webp 512`)
  - multipart image ingest parity в `account`, `users/me/profile`, `join`, `first_run`, `account/bots`.

## Непокрытые блоки до 100%

- [x] Финальный 1:1 для `Room::PushMessageJob` (ActionText mentionees vs string `@name`, формирование payload body/path во всех edge-cases).
- [x] Полный Rails-паритет для browser/platform middleware (`AllowBrowser`, `SetPlatform`) и полного HTML-ответа `sessions/incompatible_browser`.
- [x] Полный паритет `account/logo` и `users/avatar` с ActiveStorage-подобным хранением/вариантами.
- [x] Полная таблица route-to-route соответствия подготовлена: `ROUTE_PARITY_TABLE_FULL.md`.

## Открытые строгие расхождения (обновлено)

- [x] ActionCable/Turbo Streams parity:
  - добавлен `Turbo::StreamsChannel` в `/cable` с `signed_stream_name`/`stream_name` подписками и turbo-stream delivery.
  - `message.boosted` turbo target выровнен с Rails (`boosts_message_<client_message_id>`).
- [x] RichText/ActionText parity:
  - `Message` расширен `bodyHtml/bodyPlain/mentioneeIds`; add/update flow нормализует rich/plain; `action-text-attachment` (`sgid`) mentions поддержаны.
- [x] Search engine parity:
  - добавлен `MessageSearchIndex` (аналог `message_search_index`) и lifecycle sync на create/update/delete + bulk removals.
- [x] Transfer/signature format parity:
  - `transfer_id` и `attachable_sgid` переведены на Rails-style signed envelope format (не JWT).
  - добавлена совместимость с Rails payload variants (`_rails.message` и `_rails.data`) и `gid://.../User/:id`.
  - `transfer_id` верифицируется строго по подписи/TTL (без unsafe decode bypass).

## Route parity snapshot (в работе)

| Rails route | Node route | Статус |
|---|---|---|
| `GET /rooms/:room_id/messages` | `GET /api/v1/rooms/:roomId/messages` | ✅ |
| `GET /rooms/:room_id/messages/:id` | `GET /api/v1/rooms/:roomId/messages/:messageId` | ✅ |
| `PATCH /rooms/:room_id/messages/:id` | `PATCH /api/v1/rooms/:roomId/messages/:messageId` | ✅ |
| `DELETE /rooms/:room_id/messages/:id` | `DELETE /api/v1/rooms/:roomId/messages/:messageId` | ✅ |
| `GET /rooms/:room_id/refresh` | `GET /api/v1/rooms/:roomId/refresh` | ✅ |
| `GET /rooms/:room_id/involvement` | `GET /api/v1/rooms/:roomId/involvement` | ✅ |
| `PATCH /rooms/:room_id/involvement` | `PATCH /api/v1/rooms/:roomId/involvement` | ✅ |
| `GET /rooms/:room_id/settings` | `GET /api/v1/rooms/:roomId/settings` | ✅ |
| `POST /rooms/:room_id/:bot_key/messages` | `POST /api/v1/rooms/:roomId/:botKey/messages` | ✅ |
| `GET /users/me/push_subscriptions` | `GET /api/v1/users/:userId/push_subscriptions` | ✅ |
| `POST /users/me/push_subscriptions` | `POST /api/v1/users/:userId/push_subscriptions` | ✅ |
| `POST /users/me/push_subscriptions/:id/test_notifications` | `POST /api/v1/users/:userId/push_subscriptions/:push_subscription_id/test_notifications` | ✅ |
| `resource :first_run` | `GET|POST /api/v1/first_run` | ✅ |
| `resource :unfurl_link` | `POST /api/v1/unfurl_link` | ✅ |
| `resource :account` + nested routes | `GET|PATCH /api/v1/account` + `/api/v1/account/*` | ✅ |
| `resources :users` + avatar/profile/sidebar | `/api/v1/users/:id`, `/api/v1/users/:userId/avatar`, `/api/v1/users/me/profile`, `/api/v1/users/me/sidebar` | ✅ |
| `resources :qr_code`, `pwa`, `welcome` | `/qr_code/:id`, `/webmanifest`, `/service-worker`, `/` | ✅ |
