# ルーティング一覧

`config/routes.rb` の内容を機能グループごとに整理したものです。

## 初期セットアップ

| Verb | URI | Controller#Action |
|------|-----|-------------------|
| GET | `/` | `welcome#show` |
| GET | `/first_run` | `first_runs#show` |
| POST | `/first_run` | `first_runs#create` |

## セッション管理

| Verb | URI | Controller#Action |
|------|-----|-------------------|
| GET | `/session/new` | `sessions#new` |
| POST | `/session` | `sessions#create` |
| DELETE | `/session` | `sessions#destroy` |
| GET | `/session/transfers/:id` | `sessions/transfers#show` |
| PATCH | `/session/transfers/:id` | `sessions/transfers#update` |

## アカウント管理

| Verb | URI | Controller#Action |
|------|-----|-------------------|
| GET | `/account` | `accounts#show` |
| PATCH | `/account` | `accounts#update` |

### アカウント配下のユーザー管理

| Verb | URI | Controller#Action |
|------|-----|-------------------|
| GET | `/account/users` | `accounts/users#index` |
| GET | `/account/users/new` | `accounts/users#new` |
| POST | `/account/users` | `accounts/users#create` |
| GET | `/account/users/:id` | `accounts/users#show` |
| GET | `/account/users/:id/edit` | `accounts/users#edit` |
| PATCH | `/account/users/:id` | `accounts/users#update` |
| DELETE | `/account/users/:id` | `accounts/users#destroy` |

### Bot 管理

| Verb | URI | Controller#Action |
|------|-----|-------------------|
| GET | `/account/bots` | `accounts/bots#index` |
| GET | `/account/bots/new` | `accounts/bots#new` |
| POST | `/account/bots` | `accounts/bots#create` |
| GET | `/account/bots/:id` | `accounts/bots#show` |
| GET | `/account/bots/:id/edit` | `accounts/bots#edit` |
| PATCH | `/account/bots/:id` | `accounts/bots#update` |
| DELETE | `/account/bots/:id` | `accounts/bots#destroy` |
| PATCH | `/account/bots/:bot_id/key` | `accounts/bots/keys#update` |

### その他アカウント設定

| Verb | URI | Controller#Action |
|------|-----|-------------------|
| POST | `/account/join_code` | `accounts/join_codes#create` |
| GET | `/account/logo` | `accounts/logos#show` |
| DELETE | `/account/logo` | `accounts/logos#destroy` |
| GET | `/account/custom_styles/edit` | `accounts/custom_styles#edit` |
| PATCH | `/account/custom_styles` | `accounts/custom_styles#update` |

## ユーザー参加・プロフィール

### 招待リンクによる参加

| Verb | URI | Controller#Action |
|------|-----|-------------------|
| GET | `/join/:join_code` | `users#new` |
| POST | `/join/:join_code` | `users#create` |

### QR コード

| Verb | URI | Controller#Action |
|------|-----|-------------------|
| GET | `/qr_code/:id` | `qr_code#show` |

### ユーザー詳細・関連リソース

| Verb | URI | Controller#Action |
|------|-----|-------------------|
| GET | `/users/:id` | `users#show` |
| GET | `/users/:user_id/avatar` | `users/avatars#show` |
| DELETE | `/users/:user_id/avatar` | `users/avatars#destroy` |
| POST | `/users/:user_id/ban` | `users/bans#create` |
| DELETE | `/users/:user_id/ban` | `users/bans#destroy` |

### 自分のプロフィール（`user_id: "me"`）

| Verb | URI | Controller#Action |
|------|-----|-------------------|
| GET | `/users/me/sidebar` | `users/sidebars#show` |
| GET | `/users/me/profile` | `users/profiles#show` |
| PATCH | `/users/me/profile` | `users/profiles#update` |
| GET | `/users/me/push_subscriptions` | `users/push_subscriptions#index` |
| POST | `/users/me/push_subscriptions` | `users/push_subscriptions#create` |
| DELETE | `/users/me/push_subscriptions/:id` | `users/push_subscriptions#destroy` |
| POST | `/users/me/push_subscriptions/:push_subscription_id/test_notifications` | `users/push_subscriptions/test_notifications#create` |

### オートコンプリート

| Verb | URI | Controller#Action |
|------|-----|-------------------|
| GET | `/autocompletable/users` | `autocompletable/users#index` |

## ルーム

### ルーム CRUD・メッセージ

| Verb | URI | Controller#Action |
|------|-----|-------------------|
| GET | `/rooms` | `rooms#index` |
| GET | `/rooms/new` | `rooms#new` |
| POST | `/rooms` | `rooms#create` |
| GET | `/rooms/:id` | `rooms#show` |
| GET | `/rooms/:id/edit` | `rooms#edit` |
| PATCH | `/rooms/:id` | `rooms#update` |
| DELETE | `/rooms/:id` | `rooms#destroy` |
| GET | `/rooms/:room_id/messages` | `messages#index` |
| POST | `/rooms/:room_id/messages` | `messages#create` |
| GET | `/rooms/:room_id/messages/:id` | `messages#show` |
| PATCH | `/rooms/:room_id/messages/:id` | `messages#update` |
| DELETE | `/rooms/:room_id/messages/:id` | `messages#destroy` |
| POST | `/rooms/:room_id/:bot_key/messages` | `messages/by_bots#create` |
| GET | `/rooms/:room_id/@:message_id` | `rooms#show` |

### ルーム付帯リソース

| Verb | URI | Controller#Action |
|------|-----|-------------------|
| GET | `/rooms/:room_id/refresh` | `rooms/refreshes#show` |
| GET | `/rooms/:room_id/settings` | `rooms/settings#show` |
| GET | `/rooms/:room_id/involvement` | `rooms/involvements#show` |
| PATCH | `/rooms/:room_id/involvement` | `rooms/involvements#update` |

### ルーム種別

| Verb | URI | Controller#Action |
|------|-----|-------------------|
| GET | `/rooms/opens` | `rooms/opens#index` |
| POST | `/rooms/opens` | `rooms/opens#create` |
| GET | `/rooms/closeds` | `rooms/closeds#index` |
| POST | `/rooms/closeds` | `rooms/closeds#create` |
| GET | `/rooms/directs` | `rooms/directs#index` |
| POST | `/rooms/directs` | `rooms/directs#create` |

## メッセージ・ブースト

| Verb | URI | Controller#Action |
|------|-----|-------------------|
| GET | `/messages/:message_id/boosts` | `messages/boosts#index` |
| POST | `/messages/:message_id/boosts` | `messages/boosts#create` |
| DELETE | `/messages/:message_id/boosts/:id` | `messages/boosts#destroy` |

## 検索

| Verb | URI | Controller#Action |
|------|-----|-------------------|
| GET | `/searches` | `searches#index` |
| POST | `/searches` | `searches#create` |
| DELETE | `/searches/clear` | `searches#clear` |

## その他

| Verb | URI | Controller#Action |
|------|-----|-------------------|
| POST | `/unfurl_link` | `unfurl_links#create` |
| GET | `/webmanifest` | `pwa#manifest` |
| GET | `/service-worker` | `pwa#service_worker` |
| GET | `/up` | `rails/health#show` |
