# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is **CampKit**, a combination of two projects:
- **[Campfire](https://github.com/basecamp/once-campfire)** - Basecamp's web-based chat application (Rails backend, messaging, rooms, authentication)
- **[Meet](https://github.com/livekit-examples/meet)** - LiveKit's video conferencing example (video/audio/screenshare frontend)

The goal is to bring **full video conferencing and screen sharing** capabilities seamlessly into Campfire as a native feature. Users can:
- Join video calls directly within any chat room
- Share screens with system audio capture
- See active participants with avatars
- Maintain calls while navigating between rooms (persistent state)
- View ongoing calls as an observer without joining

The integration preserves Campfire's simplicity while adding Meet's powerful video features.

This is a **single-tenant application** - all "public" rooms are accessible to all users in the system. For multiple distinct user groups, deploy separate instances.

**Current branch**: `Meet` - contains the video integration work (base branch for PRs is `main`)

## Tech Stack

- **Backend** (from Campfire): Rails (main branch), SQLite, Redis, Resque (background jobs)
- **Frontend** (from Campfire): Hotwire (Turbo + Stimulus), importmap-rails, propshaft
- **Real-time Chat** (from Campfire): ActionCable for websockets (presence, typing, unread state)
- **Real-time Video** (from Meet): LiveKit client SDK, WebRTC
- **Media**: ActiveStorage, image_processing, libvips, ffmpeg
- **Testing**: Minitest (unit, controller, system tests), Capybara, Selenium

## Code Provenance

Understanding where code originates helps when debugging or extending features:

**From Campfire (Basecamp)**:
- All Rails backend code: models, controllers (except LiveKit API), views (except video UI), channels
- Chat-related JavaScript: `messages_controller.js`, `composer_controller.js`, `autocomplete_controller.js`
- Authentication, sessions, memberships, rooms, messages, push notifications
- Most styles, helpers, and view partials

**From Meet (LiveKit)**:
- `app/javascript/controllers/video_call_controller.js` - the core video conferencing logic
- `app/views/rooms/show/_video_call.html.erb` - video call UI partial
- `app/assets/stylesheets/video_call.css` - video-specific styles
- LiveKit API endpoints and controller: `app/controllers/api/livekit/livekit_controller.rb`
- LiveKit configuration: `config/initializers/livekit.rb`

**Integration/Glue Code** (original to this fork):
- Observer mode implementation in video controller
- Active call persistence across Turbo navigations
- Integration of video UI into Campfire rooms
- Participant avatar fetching from Campfire users

## Development Commands

### Setup
```bash
bin/setup              # Bootstrap dependencies and database
bin/setup --reset      # Reset database and start fresh
```

### Running the App
```bash
bin/rails server       # Start Rails server
bin/dev                # Alternative command to start server
bin/rails console      # Interactive console (REPL)
```

### Testing
```bash
bin/rails test                        # Run all unit/controller/model tests
bin/rails test:system                 # Run system tests (browser-based)
bin/rails test test/models/user_test.rb        # Run specific test file
bin/rails test test/models/user_test.rb:15     # Run specific test at line 15
```

### Code Quality
```bash
bin/rubocop            # Lint Ruby code (rubocop-rails-omakase style)
bin/brakeman           # Security vulnerability scanning
bin/bundler-audit      # Check for vulnerable gem versions
bin/ci                 # Run all CI checks locally
```

### Database
```bash
bin/rails db:prepare   # Create database and run migrations
bin/rails db:reset     # Drop, recreate, and seed database
bin/rails db:migrate   # Run pending migrations
```

### Docker
```bash
docker build -t campfire .
docker run --publish 80:80 --publish 443:443 \
  --volume campfire:/rails/storage \
  --env SECRET_KEY_BASE=$SECRET_KEY_BASE \
  campfire
```

## Architecture

### Data Model

The core domain models follow this structure:

- **Account**: Single-tenant account (singleton). Has settings, logo, join codes. Uses `Account::Joinable` concern.
- **User**: Users belong to one account. Key concerns:
  - `User::Avatar` - avatar handling with tokens
  - `User::Bot` - bot authentication via API keys
  - `User::Role` - administrator/member roles
  - `User::Bannable` - ban functionality
  - `User::Transferable` - session transfer between devices
- **Room**: Three types via STI:
  - `Rooms::Open` - accessible to all users automatically
  - `Rooms::Closed` - invite-only rooms
  - `Rooms::Direct` - 1:1 DM rooms
- **Membership**: Join table between users and rooms. Tracks:
  - `involvement` - notification level (invisible/nothing/mentions/everything)
  - `unread_at` - timestamp for unread indicator
  - `connected` - whether user has active websocket connection
- **Message**: Messages belong to rooms and creators. Key concerns:
  - `Message::Attachment` - file upload handling
  - `Message::Mentionee` - @mention parsing and linking
  - `Message::Searchable` - full-text search
  - `Message::Pagination` - geared_pagination integration
  - Has rich text body via ActionText
- **Session**: Device/browser sessions for users. Tracks IP, user agent, last activity.
- **Webhook**: Bot webhook configurations for API integrations.

### Key Relationships

```
Account (singleton)
  └─ Users (has_many)
       ├─ Memberships (has_many)
       │    └─ Room (belongs_to)
       ├─ Messages (has_many, as creator_id)
       ├─ Sessions (has_many)
       ├─ Boosts (has_many, as booster_id)
       └─ Push::Subscriptions (has_many)

Room (STI: Open/Closed/Direct)
  ├─ Memberships (has_many)
  │    └─ Users (through memberships)
  └─ Messages (has_many)
       └─ Boosts (has_many)
```

### Current Context

The `Current` class (ActiveSupport::CurrentAttributes) stores request-scoped state:
- `Current.user` - currently authenticated user
- `Current.session` - current session
- `Current.request` - current request
- `Current.account` - the singleton account (always `Account.first`)

### Authentication

Authentication is handled via the `Authentication` concern:
- **Session-based**: Cookie-based sessions for web users (`find_session_by_cookie`)
- **Bot-based**: API key authentication via `?bot_key=` parameter for bot integrations
- Protected from forgery unless authenticated as bot
- Controllers can use `allow_unauthenticated_access` or `allow_bot_access` to skip auth

### Real-time Features

ActionCable channels power real-time updates:
- `RoomChannel` - room messages, typing indicators
- `PresenceChannel` - user online/offline status
- `ReadRoomsChannel` - read receipts
- `UnreadRoomsChannel` - unread counts
- `TypingNotificationsChannel` - typing indicators

Channels use `Current.user` for identification via `ApplicationCable::Connection`.

### Background Jobs

Resque handles async work:
- `Room::PushMessageJob` - send Web Push notifications for new messages
- `Bot::WebhookJob` - trigger bot webhooks for events

### Frontend Architecture

**Stimulus controllers** (from Campfire):
- `messages_controller.js` - message rendering, pagination, scroll management
- `composer_controller.js` - message composition, file uploads
- `autocomplete_controller.js` - @mentions autocomplete
- `notifications_controller.js` - Web Push subscription management
- `presence_controller.js` - user online/offline indicators
- `typing_notifications_controller.js` - "X is typing..." indicators
- `rooms_list_controller.js` - sidebar room list management
- `read_rooms_controller.js` - mark rooms as read
- Plus ~20 other utility controllers (lightbox, copy-to-clipboard, etc.)

**Stimulus controllers** (from Meet):
- `video_call_controller.js` - LiveKit video conferencing integration (see "LiveKit Video Integration" section)

**JavaScript models and helpers** (from Campfire):
- `models/client_message.js` - optimistic UI for sending messages
- `models/message_paginator.js` - infinite scroll pagination
- `models/scroll_manager.js` - smart scroll behavior
- `models/typing_tracker.js` - typing state management
- `lib/autocomplete/` - full @mention autocomplete system with custom elements

### LiveKit Video Integration (Meet)

Video conferencing is integrated from the **LiveKit Meet** example, providing a full-featured video call experience:

**Backend (Campfire)**:
- **API endpoints**:
  - `POST /api/livekit/token` - Generate access tokens for video rooms (supports `mode: "observe"` for passive watching)
  - `GET /api/livekit/participant_avatar` - Fetch participant avatar URLs for display
- **Controller**: `app/controllers/api/livekit/livekit_controller.rb`
- **Config**: `config/initializers/livekit.rb`
- **Required env vars**: `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET`
- Room names are based on Campfire room IDs; participant identity is user ID

**Frontend (Meet)**:
- **Main controller**: `app/javascript/controllers/video_call_controller.js` (~2100 lines)
  - Manages full lifecycle: connect, disconnect, reconnection with exponential backoff
  - Camera/microphone controls with mute/unmute
  - **Screen sharing with audio capture** - key feature from Meet
  - Adaptive video quality based on connection (1080p → 360p)
  - Observer mode - see active calls without joining
  - Persistent active call state - survives Turbo navigation across rooms
  - Avatar placeholders when video is off
  - Remote participant controls (mute, fullscreen)
  - Error handling with user-friendly messages
- **View**: `app/views/rooms/show/_video_call.html.erb` - video call UI
- **Styles**: `app/assets/stylesheets/video_call.css`
- **Dependencies**: Loads `livekit-client@2.15.13` from CDN

**Key Integration Patterns**:
- **Active call persistence**: Uses `window.CampfireVoice` global store to maintain video call state across Turbo frame navigations
- **Observer pattern**: When navigating to a room with an active call elsewhere, creates an observer connection to show participants
- **Dual connection modes**:
  - Active participant (publishes camera/mic/screen)
  - Observer (subscribes only, no publishing)
- **Turbo-aware**: Binds/unbinds event handlers on Turbo navigation to prevent memory leaks
- **Track management**: Carefully manages local/remote video/audio tracks, screen share tracks
- **Quality adaptation**: Automatically adjusts video resolution (1080p/720p/540p/360p) based on connection quality
- **Screen sharing with audio**: Key Meet feature - captures both screen video and system audio (Chrome/Edge)
  - Publishes as separate track with `Track.Source.ScreenShare` metadata
  - Replaces camera view temporarily, keeps camera published
  - Auto-stops when user ends share via browser UI

## Configuration & Environment Variables

### Required
- `SECRET_KEY_BASE` - Rails secret key

### Optional
- `SSL_DOMAIN` - Enable automatic SSL via Let's Encrypt
- `DISABLE_SSL` - Serve over plain HTTP instead
- `VAPID_PUBLIC_KEY` / `VAPID_PRIVATE_KEY` - Web Push notifications (generate via `/script/admin/create-vapid-key`)
- `SENTRY_DSN` - Error reporting to Sentry
- `REDIS_URL` - Redis connection URL (defaults to localhost:6379)

### Video Conferencing (LiveKit)
These are **optional** but required to enable video features:
- `LIVEKIT_URL` - LiveKit server WebSocket URL (e.g., `wss://livekit.example.com`)
- `LIVEKIT_API_KEY` - LiveKit API key for token generation
- `LIVEKIT_API_SECRET` - LiveKit API secret for token generation

If not configured, the video call button will be disabled with a "LiveKit is not configured" message. The app functions normally as a chat-only application without these variables.

## Testing Strategy

- **Minitest** framework with fixtures in `test/fixtures/`
- **Unit tests**: `test/models/` for model logic
- **Controller tests**: `test/controllers/` for HTTP responses
- **System tests**: `test/system/` for full browser workflows (Selenium + Capybara)
- **Channel tests**: `test/channels/` for ActionCable
- Tests use `setup` and `teardown` methods, not RSpec-style contexts
- Fixtures are loaded automatically from `test/fixtures/*.yml`

## Code Style & Conventions

- **Ruby style**: Rails Omakase (enforced via `.rubocop.yml`)
- **Naming**: `snake_case` for files/methods, `CamelCase` for classes
- **Concerns**: Heavy use of concerns for model mixins (see `app/models/concerns/`)
- **Views**: ERB templates in `app/views/`, partials prefixed with `_`
- **Stimulus**: Targets use `data-controller-target-name` attributes
- **Turbo**: Extensive use of Turbo Streams for real-time DOM updates via ActionCable

## Important Patterns

### Broadcasting Updates

Use `Turbo::Streams::Broadcasts` for real-time updates:
```ruby
broadcast_replace_to user, :rooms, target: dom_id(room, :list), html: html
broadcast_remove_to user, :rooms, target: dom_id(room, :list)
broadcast_prepend_to user, :rooms, target: :shared_rooms, html: html
```

### Room Membership

Rooms use a custom `memberships` association extension for granting/revoking access:
```ruby
room.memberships.grant_to(users)
room.memberships.revoke_from(users)
room.memberships.revise(granted: [...], revoked: [...])
```

### Message Reception

When a message is created, `room.receive(message)` handles:
1. Marking memberships as unread (except for creator and connected users)
2. Enqueuing push notification jobs

### First Run Setup

`FirstRun` model handles initial admin account creation. First user to visit becomes admin.

## Working with Video Integration

The video integration is complex and touches multiple layers:

### Video Controller Architecture

The `video_call_controller.js` Stimulus controller is the heart of the Meet integration:
- **Private fields** (prefixed with `#`) store state: room, tracks, participants, connection credentials
- **Lifecycle methods**:
  - `connect()` - Initialize, adopt active calls, ensure observer if needed
  - `disconnect()` - Persist or cleanup based on user intent
  - `startVideoCall()` - Fetch token, connect to LiveKit, enable camera/mic
  - `leave()` - User-initiated disconnect, cleanup all tracks
- **Track management**:
  - Local tracks: `#localVideoTrack`, `#localAudioTrack`, `#localScreenTrack`
  - Remote tracks: stored in `#remoteParticipants` Map
  - Screen share includes both video and audio tracks
- **Reconnection logic**:
  - Exponential backoff (1s, 2s, 4s, 8s, 16s, max 30s)
  - Max 10 reconnection attempts
  - Preserves connection credentials for reconnection
- **State persistence**:
  - Active call stored in `window.CampfireVoice.active`
  - Allows seamless Turbo navigation while maintaining call
  - Observer mode for viewing calls from other rooms

### Debugging Video Issues

Common areas to check:
- **Connection state**: Look for `video-call--connecting`, `video-call--connected`, `video-call--reconnecting` CSS classes
- **Track publishing**: Check `LocalParticipant.publishTrack()` calls in console
- **Token generation**: Backend `/api/livekit/token` must return valid tokens
- **LiveKit config**: Ensure `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` are set
- **Browser permissions**: Camera/microphone must be allowed
- **Screen share audio**: Chrome/Edge support audio capture, Firefox/Safari may not

### Adding Video Features

When extending video functionality:
1. **Modify `video_call_controller.js`** for frontend behavior
2. **Update `_video_call.html.erb`** for UI elements, add Stimulus targets
3. **Add to `video_call.css`** for styles
4. **Test reconnection** - ensure feature works across disconnects
5. **Test Turbo navigation** - ensure state persists or cleans up correctly
6. **Test observer mode** - ensure non-participants can see the feature

## Common Tasks

### Adding a New Model
1. Generate migration: `bin/rails generate migration CreateThings`
2. Run migration: `bin/rails db:migrate`
3. Create model in `app/models/`
4. Add tests in `test/models/`
5. Update `db/structure.sql` with `bin/rails db:migrate`

### Adding a New Controller
1. Create controller in `app/controllers/`
2. Add routes in `config/routes.rb`
3. Create views in `app/views/controller_name/`
4. Add tests in `test/controllers/`

### Adding a Stimulus Controller
1. Create `app/javascript/controllers/name_controller.js`
2. Export in `app/javascript/controllers/index.js` (if needed)
3. Use in views via `data-controller="name"`

### Working with Tests
- Fixtures are defined in `test/fixtures/*.yml`
- Use `assert`, `assert_equal`, `assert_difference` for assertions
- System tests can use Capybara matchers: `assert_selector`, `fill_in`, `click_on`

## Security Considerations

- SSRF protection via `RestrictedHTTP::PrivateNetworkGuard` for link unfurling
- CSRF protection enabled (except for bot API key authentication)
- XSS protection via ActionView escaping and content security policy
- SQL injection protection via ActiveRecord parameterization
- Command injection prevention in file handling (vips, ffmpeg)
- Brakeman scans for vulnerabilities in CI

## Contribution Workflow

1. Discussions first, then issues (see `CONTRIBUTING.md`)
2. Issues represent agreed-upon actionable tasks
3. PRs should reference issue/discussion
4. Include tests for new features
5. Ensure `bin/ci` passes before pushing
