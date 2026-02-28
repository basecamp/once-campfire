# ROUTE_PARITY_TABLE_FULL

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
| 42 | `POST /rooms` (`rooms#create` via rooms/opens|closeds` flow in Rails UI`) | `POST /rooms` | DONE | |
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
