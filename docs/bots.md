# Bot integrations

Campfire bots can post and manage messages, upload files, read room history, add
boosts, and react to messages and interactive actions through a webhook.

## Setup and authentication

An administrator creates a bot under **Settings → Chat bots**, where its name,
avatar, and optional webhook URL can be configured. Add the bot to each room it
should access. The Chat bots page shows a posting URL for every room the bot is
a member of:

```text
https://chat.example.com/rooms/ROOM_ID/BOT_KEY/messages
```

The `BOT_KEY` in that path authenticates the bot. Treat the complete URL as a
secret. Resetting the key invalidates old URLs, and deactivating the bot removes
its API access. A valid bot receives `404 Not Found` when it tries to use a room
it has not joined.

Examples below use this base URL:

```sh
BOT_URL=https://chat.example.com/rooms/1/BOT_KEY
```

## API overview

| Method | Path relative to `BOT_URL` | Purpose |
| --- | --- | --- |
| `GET` | `/messages` | Read messages in the room. |
| `POST` | `/messages` | Send text, a file, or a message with actions. |
| `PATCH` | `/messages/:id` | Update one of the bot's messages. |
| `DELETE` | `/messages/:id` | Delete one of the bot's messages. |
| `POST` | `/messages/:message_id/boosts` | Boost any message in the room. |
| `DELETE` | `/messages/:message_id/boosts/:id` | Remove one of the bot's boosts. |

A bot can update or delete only content it created itself. It can read and boost
other people's messages in rooms it can access.

## Sending messages and files

Post a plain request body to create an ordinary text message:

```sh
curl -d 'Hello!' "$BOT_URL/messages"
```

Upload one attachment as multipart form data:

```sh
curl -F 'attachment=@/path/to/report.pdf' "$BOT_URL/messages"
```

The request must contain non-blank text or an attachment. A successful create
returns `201 Created`, the new message as JSON, and its regular Campfire URL in
the `Location` header.

## Reading messages

```sh
curl "$BOT_URL/messages"
```

The response is a JSON array in chronological order. Each item has this shape:

```json
{
  "id": 123,
  "created_at": "2026-08-17T12:34:56.789Z",
  "body": {
    "plain_text": "Hello!",
    "html": "<div class=\"trix-content\">Hello!</div>"
  },
  "selection_mode": "none",
  "actions": [],
  "creator": {
    "id": 42,
    "name": "Ada",
    "role": "member",
    "avatar_url": "https://chat.example.com/..."
  },
  "room": { "id": 1 },
  "url": "https://chat.example.com/rooms/1/messages/123"
}
```

Campfire returns at most 40 messages per request. With no cursor it returns the
latest page. Follow the URL in the `Link` response header, whose relation is
`next`, to load older pages. Use `?after=MESSAGE_ID` to poll forward from a
known message; its `Link` header continues forward if more than one page is
available. You can also request the page immediately preceding a message with
`?before=MESSAGE_ID`. `X-Total-Count` contains the room's total message count.

## Updating and deleting messages

Plain text can replace a message created by the bot:

```sh
curl -X PATCH -d 'Deployment finished.' "$BOT_URL/messages/123"
```

The update response contains the same JSON representation used by the messages
index. Delete the bot's message with:

```sh
curl -X DELETE "$BOT_URL/messages/123"
```

A successful delete returns `204 No Content`.

## Boosts

A boost can be an emoji or short text of at most 16 characters. Post it as the
raw request body:

```sh
curl -d '👀' "$BOT_URL/messages/123/boosts"
```

Campfire returns `201 Created` with the boost:

```json
{
  "id": 456,
  "content": "👀",
  "created_at": "2026-08-17T12:34:56.789Z",
  "booster": {
    "id": 7,
    "name": "Deploy bot",
    "role": "bot",
    "avatar_url": "https://chat.example.com/..."
  },
  "message": {
    "id": 123,
    "url": "https://chat.example.com/rooms/1/messages/123"
  }
}
```

Remove a boost created by this bot using its returned ID:

```sh
curl -X DELETE "$BOT_URL/messages/123/boosts/456"
```

## Receiving message webhooks

When a webhook URL is configured, Campfire sends it an HTTP `POST` with
`Content-Type: application/json`:

```json
{
  "type": "message",
  "user": { "id": 42, "name": "Ada" },
  "room": {
    "id": 1,
    "name": "Lobby",
    "path": "/rooms/1/BOT_KEY/messages"
  },
  "message": {
    "id": 123,
    "body": { "html": "Hello bot", "plain": "Hello bot" },
    "path": "/rooms/1/at/123"
  }
}
```

In a regular room, the webhook is sent when the bot is mentioned. The bot's
mention is removed from `message.body.plain`. In a direct room containing the
bot, it is sent for messages from the other participant. Messages sent by the
bot itself never trigger its own webhook.

The webhook has seven seconds to respond. A `200 OK` response with a
`text/plain` or `text/html` content type posts the response body as a new message
from the bot. A successful response with a recognized file MIME type posts the
body as an attachment. Other responses create no reply. If the connection or
response times out, Campfire posts a timeout message from the bot.

Webhook requests are not signed. Use an unguessable HTTPS endpoint and apply
appropriate network controls at the receiving service.

## Interactive actions

Send JSON to put buttons on a message:

```sh
curl -H 'Content-Type: application/json' \
  -d '{
    "body": "Where should we have lunch?",
    "selection_mode": "single",
    "actions": [
      { "label": "Pizza", "value": "lunch:pizza", "emoji": "🍕" },
      { "label": "Sushi", "value": "lunch:sushi", "emoji": "🍣" }
    ]
  }' \
  "$BOT_URL/messages"
```

A message can contain up to 12 actions.

### Selection modes

`selection_mode` controls the selected state shown to each user:

- `none` (default) sends every click without retaining a selected state.
- `single` selects at most one action. Clicking the selected action clears it.
- `multiple` allows independent selections. Clicking a selected action clears it.

Selections are stored per user and restored when they reload or return later.
Changing the action values or `selection_mode` clears existing selections.

### Action fields

Every action requires a non-blank `label` of at most 40 characters. The label is
also the accessible name and desktop tooltip for icon-only actions. Values must
be unique within a message so each callback and selected state identifies one
button unambiguously.

An action must have exactly one destination:

- `value`: up to 200 characters, sent to the bot's webhook when a user activates
  the action.
- `url`: an absolute URL of up to 2,048 characters, opened without calling the
  webhook or changing selection state.

The following optional fields control appearance and behavior:

| Field | Values | Behavior |
| --- | --- | --- |
| `style` | `default`, `primary`, `danger` | Uses a built-in Campfire button style. |
| `icon` | A bundled icon name | Adds a local Campfire icon. Cannot be combined with `emoji`. |
| `emoji` | One emoji grapheme | Adds an emoji. Cannot be combined with `icon`. |
| `icon_position` | `left`, `right` | Places the icon or emoji; defaults to `left`. |
| `icon_only` | `true`, `false` | Visually hides the label and renders a round button. Requires an icon or emoji. |
| `background_color` | Hex color | Sets the background, for example `#2563eb` or `#abc`. |
| `text_color` | Hex color | Overrides automatic black/white contrast. Requires `background_color`. |
| `disabled` | `true`, `false` | Shows a non-interactive action and rejects forged callback requests. |

Bundled icon names are:

```text
add alert arrow-down arrow-left arrow-right arrow-up attachment bot camera cancel
check download globe help help-circle link lock messages notification-bell-alert
pencil person refresh reply search settings share trash web
```

Link actions accept absolute URLs with a scheme. Campfire rejects relative URLs
and unsafe `data`, `file`, `javascript`, and `vbscript` schemes. HTTP and HTTPS
links must have a host and cannot contain embedded credentials. Prefer an app's
HTTPS universal link when opening a native application from a mobile browser.

Every other scheme is accepted so bots can deep-link into native apps, which
makes the scheme caller-trusted: whoever controls the bot decides what a room
member's browser is asked to open. Give a bot key only to a service you trust to
that degree, and prefer `https` whenever it will do.

Actions are bot UI. A message created by anyone other than a bot is rejected if
it carries actions, even when it reaches these endpoints with a signed-in
session rather than a bot key.

### Action webhooks

Activating a value action sends JSON to the bot's configured webhook URL:

```json
{
  "type": "action",
  "id": "2b1a5135-fd38-4667-950b-3ada8e366f20",
  "room": {
    "id": 1,
    "name": "Lobby",
    "path": "/rooms/1/BOT_KEY/messages"
  },
  "user": { "id": 42, "name": "Ada" },
  "message": { "id": 123, "path": "/rooms/1/at/123" },
  "action": { "value": "lunch:pizza", "selected": true }
}
```

`selected` reports the user's resulting selection state. It is always `false`
when the message uses `selection_mode: "none"`.

`room.path` is the authenticated bot messages endpoint. Append the message ID
to update the original message. `message.path` opens the message in Campfire.

Campfire accepts the click with `202 Accepted` and delivers the webhook in a
background job. Failed connections, timeouts, and HTTP error responses are
retried up to five times. Retries retain the same top-level `id`; bots should
store that ID and ignore callbacks they have already processed. Action callback
requests are limited to 30 per minute. The endpoint has seven seconds to respond,
but its successful response body is ignored. Update the original message
explicitly when its content or actions should change.

Value actions require a configured webhook and are rejected when the bot does
not have one. Removing a bot's webhook disables its existing value actions.
Link actions do not require a webhook.

### Updating and closing actions

Use the message ID from the `Location` header to replace a bot message and its
actions:

```sh
curl -X PATCH -H 'Content-Type: application/json' \
  -d '{
    "body": "Voting has closed.",
    "selection_mode": "single",
    "actions": [
      { "label": "Pizza", "value": "lunch:pizza", "emoji": "🍕", "disabled": true },
      { "label": "Sushi", "value": "lunch:sushi", "emoji": "🍣", "disabled": true }
    ]
  }' \
  "$BOT_URL/messages/123"
```

At a deadline the bot can disable the actions, remove them with `"actions": []`,
or update the message with the result.

## Common responses

- `201 Created`: a message, attachment, or boost was created.
- `202 Accepted`: an action callback was queued.
- `204 No Content`: a delete succeeded.
- `400 Bad Request`: the request was malformed, such as asking for the selected
  state of more messages than one request allows.
- `404 Not Found`: the room, message, or bot-owned resource is inaccessible.
- `422 Unprocessable Content`: required content is missing, or an action is
  invalid or malformed. JSON validation failures include an `errors` object keyed
  by field. A malformed `actions` value is rejected rather than ignored, so a
  `2xx` always means the actions were stored exactly as sent.
- `429 Too Many Requests`: a user exceeded the action-click rate limit.
