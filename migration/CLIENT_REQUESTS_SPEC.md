# Клиентские запросы к новому JSON API

Документ описывает, какие запросы должен делать frontend после разделения монолита.

## 1. Общие правила

- Базовый префикс API: `/api/v1`.
- Сервер возвращает только JSON.
- Все даты: ISO-8601 UTC.
- Все id: string (Mongo ObjectId).

## 2. Авторизация через внешний middleware

Backend не логинит пользователя сам, а читает контекст из middleware.

Клиент должен отправлять:

- Header: `x-device-id`
- Header: `x-authentication-token` (если есть)
- Cookie: `refreshToken` (httpOnly, выставляется внешним auth сервисом)

Если middleware обновил access token, backend вернет новый header:

- `x-authentication-token: <new-token>`

Клиент обязан перезаписать access token в своем хранилище.

## 3. Единый формат ответа

Успех:

```json
{
  "data": {}
}
```

Ошибка:

```json
{
  "error": {
    "code": "VALIDATION_ERROR",
    "message": "Validation failed",
    "details": {
      "field": "name"
    }
  }
}
```

## 4. Bootstrap и профиль

### `GET /users/me/sidebar`

Назначение: список комнат в sidebar + direct placeholders.

### `GET /users/me/profile`

Назначение: карточка текущего пользователя + memberships.

### `PATCH /users/me/profile`

Request:

```json
{
  "name": "Ruslan",
  "bio": "Backend engineer",
  "emailAddress": "ruslan@example.com",
  "password": "new-password"
}
```

Response: обновленный профиль.

## 5. Account/Admin API

### `GET /account`

- Возвращает `name`, `settings`, `joinCode`, `logo`.

### `PATCH /account`

Request:

```json
{
  "name": "Campfire",
  "settings": {
    "restrictRoomCreationToAdministrators": false
  },
  "logoFileId": "file_123"
}
```

### `GET /account/users`

- Активные пользователи без ботов.

### `PATCH /account/users/:id`

Request:

```json
{
  "role": "administrator"
}
```

### `DELETE /account/users/:id`

- Деактивация пользователя (parity с `deactivate`).

### `GET /account/bots`
### `POST /account/bots`
### `PATCH /account/bots/:id`
### `DELETE /account/bots/:id`
### `PATCH /account/bots/:id/key`

Bot create/update request:

```json
{
  "name": "Deploy Bot",
  "webhookUrl": "https://example.org/bot"
}
```

### `POST /account/join_code`

- Сброс join-code.

### `GET /account/logo`

Только JSON:

```json
{
  "data": {
    "logo": {
      "url": "https://cdn.example.com/account/logo.png",
      "contentType": "image/png",
      "updatedAt": "2026-03-01T10:00:00.000Z"
    }
  }
}
```

### `DELETE /account/logo`
### `GET /account/custom_styles`
### `PATCH /account/custom_styles`

## 6. Users API

### `GET /users/:id`

- Публичный профиль пользователя.

### `GET /users/:userId/avatar`

JSON-ответ с URL/metadata (без binary в response body).

### `DELETE /users/:userId/avatar`

- Удаляет только свой аватар.

### `POST /users/:userId/ban`
### `DELETE /users/:userId/ban`

- Только администратор.

### `GET /autocompletable/users?query=<q>&roomId=<id>`

- Поиск пользователей для mention/direct.

## 7. Rooms API

### `GET /rooms`

- Список доступных комнат.

### `GET /rooms/:roomId`

- Детали комнаты + последняя страница сообщений.

### `GET /rooms/:roomId/@:messageId`

- Открытие комнаты с якорем на сообщение (page around).

### `DELETE /rooms/:roomId`

- Удаление комнаты (проверка `can_administer?`).

### `POST /rooms/opens`

Request:

```json
{
  "name": "General"
}
```

### `PATCH /rooms/opens/:id`

- Изменение name/type с parity поведения.

### `POST /rooms/closeds`

Request:

```json
{
  "name": "Core Team",
  "userIds": ["u1", "u2", "u3"]
}
```

### `PATCH /rooms/closeds/:id`

- Обновляет name и membership `grant/revoke`.

### `POST /rooms/directs`

Request:

```json
{
  "userIds": ["u2"]
}
```

- Сервер обязан вернуть существующую direct-room, если набор участников уже существует.

### `GET /rooms/:roomId/involvement`
### `PATCH /rooms/:roomId/involvement`

Request:

```json
{
  "involvement": "mentions"
}
```

Допустимые значения: `invisible | nothing | mentions | everything`.

### `GET /rooms/:roomId/refresh?since=<unix_ms>`

Response:

```json
{
  "data": {
    "newMessages": [],
    "updatedMessages": []
  }
}
```

## 8. Messages API

### `GET /rooms/:roomId/messages?before=<messageId>`
### `GET /rooms/:roomId/messages?after=<messageId>`

- Page size parity: `40`.

### `POST /rooms/:roomId/messages`

Text request:

```json
{
  "body": "Hello team",
  "clientMessageId": "c6ab7e7f-2ea5-47c5-94bf-ae5cd46afeb1"
}
```

Attachment: `multipart/form-data` + поле `attachment`.

### `POST /rooms/:roomId/:botKey/messages`

- Bot-only endpoint.
- Поддержка text body и binary attachment.

### `GET /rooms/:roomId/messages/:messageId`
### `PATCH /rooms/:roomId/messages/:messageId`
### `DELETE /rooms/:roomId/messages/:messageId`

## 9. Boosts API

### `GET /messages/:messageId/boosts`
### `POST /messages/:messageId/boosts`

Request:

```json
{
  "content": "👍"
}
```

### `DELETE /messages/:messageId/boosts/:boostId`

## 10. Search API

### `GET /searches?q=<query>`

- Возвращает найденные сообщения и список недавних запросов.

### `POST /searches`

Request:

```json
{
  "q": "deploy failed"
}
```

- Сервер нормализует запрос и сохраняет top-10 recent.

### `DELETE /searches/clear`

- Очищает историю поиска пользователя.

## 11. Push subscriptions API

### `GET /users/me/push_subscriptions`
### `POST /users/me/push_subscriptions`

Request:

```json
{
  "endpoint": "https://fcm.googleapis.com/...",
  "p256dhKey": "....",
  "authKey": "...."
}
```

### `DELETE /users/me/push_subscriptions/:id`
### `POST /users/me/push_subscriptions/:id/test_notifications`

## 12. Unfurl / utility API

### `POST /unfurl_link`

Request:

```json
{
  "url": "https://example.com/article"
}
```

Response (если valid opengraph):

```json
{
  "data": {
    "title": "Article title",
    "url": "https://example.com/article",
    "description": "....",
    "image": "https://example.com/image.jpg"
  }
}
```

Если invalid: `204` без body.

### `GET /qr_code/:id`

- JSON-only режим:

```json
{
  "data": {
    "svg": "<svg .../>"
  }
}
```

## 13. Realtime API (для клиента)

### `GET /realtime/stream`

- SSE поток событий.

Ожидаемые события:

- `room.created`
- `room.updated`
- `room.removed`
- `message.created`
- `message.updated`
- `message.removed`
- `message.boosted`
- `message.boost_removed`
- `room.unread`
- `room.read`
- `typing.start`
- `typing.stop`
- `presence.present`
- `presence.absent`

### Presence/Typing control

- `POST /realtime/rooms/:roomId/presence/present`
- `POST /realtime/rooms/:roomId/presence/absent`
- `POST /realtime/rooms/:roomId/presence/refresh`
- `POST /realtime/rooms/:roomId/typing/start`
- `POST /realtime/rooms/:roomId/typing/stop`

## 14. Обработка ошибок на клиенте

- `401`: очистить локальный access token, отправить пользователя в auth flow.
- `403`: показать `forbidden`.
- `404`: показать `not found`.
- `409`: конфликт состояния (например, гонка refresh/обновления).
- `422`: показать валидационные ошибки формы.
- `429`: throttle/retry с exponential backoff.

## 15. Минимальный порядок вызовов после загрузки приложения

1. Поднять SSE `GET /realtime/stream`.
2. Загрузить `GET /users/me/sidebar`.
3. Загрузить `GET /users/me/profile`.
4. Открыть текущую комнату `GET /rooms/:roomId`.
5. Для скролл-пагинации использовать `GET /rooms/:roomId/messages?before|after`.
6. Для near-real-time синхронизации fallback'ом дергать `GET /rooms/:roomId/refresh?since=...`.

