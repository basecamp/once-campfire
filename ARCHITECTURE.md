# Campfire Architecture Documentation

This document provides detailed technical documentation of Campfire's architecture, data models, and system design.

## Table of Contents

1. [System Overview](#system-overview)
2. [Data Models](#data-models)
3. [Authentication & Authorization](#authentication--authorization)
4. [Real-time Features](#real-time-features)
5. [Background Jobs](#background-jobs)
6. [Notification System](#notification-system)
7. [Bot Integration](#bot-integration)
8. [Search Implementation](#search-implementation)
9. [File Storage](#file-storage)
10. [Performance Considerations](#performance-considerations)

## System Overview

Campfire is built on Ruby on Rails (main branch) with a modern stack optimized for real-time collaboration:

```
┌─────────────────────────────────────────────────────────────┐
│                        Web Browser                           │
│  (Turbo + Stimulus + ActionCable WebSocket Connection)      │
└─────────────────────────────────────────────────────────────┘
                            │
                            ↓
┌─────────────────────────────────────────────────────────────┐
│                     Thruster / Puma                          │
│              (HTTP/HTTPS + WebSocket Server)                 │
└─────────────────────────────────────────────────────────────┘
                            │
                            ↓
┌─────────────────────────────────────────────────────────────┐
│                    Rails Application                         │
│  ┌────────────────┐  ┌────────────────┐  ┌──────────────┐  │
│  │  Controllers   │  │  ActionCable   │  │   ActiveJob  │  │
│  │  (HTTP/JSON)   │  │   (WebSocket)  │  │   (Resque)   │  │
│  └────────────────┘  └────────────────┘  └──────────────┘  │
│  ┌────────────────────────────────────────────────────────┐ │
│  │              Models (ActiveRecord)                     │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
                            │
        ┌───────────────────┼───────────────────┐
        ↓                   ↓                   ↓
┌──────────────┐   ┌──────────────┐   ┌──────────────┐
│   SQLite3    │   │    Redis     │   │ ActiveStorage│
│   (Data +    │   │  (Cache +    │   │  (Files +    │
│   FTS5)      │   │   Jobs)      │   │  Images)     │
└──────────────┘   └──────────────┘   └──────────────┘
```

### Technology Stack

- **Web Framework**: Ruby on Rails (main branch - edge Rails)
- **Database**: SQLite3 with FTS5 full-text search extension
- **Cache & Jobs**: Redis 5.4+
- **Job Queue**: Resque 2.7 with resque-pool
- **Web Server**: Puma 6.6 with Thruster reverse proxy
- **Real-time**: ActionCable (WebSocket) with Redis adapter
- **Frontend**: Hotwire (Turbo + Stimulus), ImportMaps
- **Assets**: Propshaft (modern asset pipeline)
- **Rich Text**: ActionText with Trix editor
- **File Processing**: image_processing gem with libvips/ImageMagick
- **Notifications**: web-push gem with VAPID authentication

## Data Models

### Entity Relationship Overview

```
User ──────< Membership >────── Room (STI)
 │                                │  ├─ Rooms::Open
 │                                │  ├─ Rooms::Closed
 │                                │  └─ Rooms::Direct
 │                                │
 ├──< Session                     ├──< Message
 ├──< Push::Subscription          │     ├─ rich_text_body (ActionText)
 └──< Boost                       │     ├─ attachment (ActiveStorage)
                                  │     └──< Boost
      Account (singleton)         │
       ├─ logo (ActiveStorage)    └──< Webhook
       └─ join_code
```

### Core Models

#### User

**Purpose**: Central identity model representing people and bots in the system.

**Schema**:
```ruby
# app/models/user.rb
class User < ApplicationRecord
  # Attributes
  name: string              # Display name
  email_address: string     # Unique email (indexed)
  password_digest: string   # BCrypt hashed password
  role: integer            # Enum: member(0), administrator(1), bot(2)
  avatar_key: string       # ActiveStorage blob key
  deactivated_at: datetime # Soft delete timestamp

  # Relationships
  has_many :sessions
  has_many :memberships
  has_many :rooms, through: :memberships
  has_many :messages, foreign_key: :creator_id
  has_many :boosts, foreign_key: :booster_id
  has_many :push_subscriptions
  has_many :searches

  # Modules
  include Avatar              # Avatar attachment handling
  include Bot                 # Bot token & API authentication
  include Mentionable         # ActionText mention rendering
  include Role                # Role-based authorization
  include Transferable        # Ownership transfer on deletion
end
```

**Key Methods**:
- `administrator?`, `member?`, `bot?` - Role checking
- `can_administer?(record)` - Authorization check
- `authenticate_bot(bot_key)` - Bot token validation
- `deactivate` - Soft delete with data preservation
- `reset_remote_connections` - Force WebSocket reconnection

**Business Logic**:
- Auto-granted membership to all open rooms on creation
- Password validation via `has_secure_password`
- Transfers ownership of created resources before destruction
- Deactivation obfuscates email but preserves messages

#### Room

**Purpose**: Chat spaces with three distinct types via Single Table Inheritance.

**Schema**:
```ruby
# app/models/room.rb (base class)
class Room < ApplicationRecord
  # Attributes
  name: string              # Room display name
  type: string             # STI discriminator (Rooms::Open, Closed, Direct)
  description: text        # Room purpose/topic
  creator_id: integer      # User who created the room

  # Relationships
  belongs_to :creator, class_name: "User"
  has_many :memberships, dependent: :destroy
  has_many :users, through: :memberships
  has_many :messages, dependent: :destroy
  has_many :webhooks, dependent: :destroy

  # STI subclasses
  # Rooms::Open - Public, auto-join for all users
  # Rooms::Closed - Private, invitation-only
  # Rooms::Direct - DM rooms, singleton per user set
end
```

**Room Types**:

1. **Rooms::Open** (`app/models/rooms/open.rb`)
   - Public rooms visible to all users
   - Auto-grant membership to new users
   - Default notification level: "mentions"
   - Use case: Team-wide channels

2. **Rooms::Closed** (`app/models/rooms/closed.rb`)
   - Private rooms with explicit membership
   - Invitation-only access
   - Use case: Private team discussions

3. **Rooms::Direct** (`app/models/rooms/direct.rb`)
   - Singleton pattern: one room per user set
   - `find_or_create_for(users)` ensures uniqueness
   - Default notification level: "everything"
   - Use case: 1-on-1 or group DMs

**Key Methods**:
- `receive(message)` - Process incoming message (mark unread, queue notifications)
- `default_involvement` - Notification default for type
- `grant_to(user)`, `revoke_from(user)` - Membership management
- Room type predicates: `open?`, `closed?`, `direct?`

#### Message

**Purpose**: Chat messages with rich content, attachments, and metadata.

**Schema**:
```ruby
# app/models/message.rb
class Message < ApplicationRecord
  # Attributes
  room_id: integer             # Parent room
  creator_id: integer          # Sender user
  client_message_id: string    # Idempotency key (indexed, unique)
  subject: string              # Message title (optional)
  created_at: datetime
  updated_at: datetime

  # Rich text content (via ActionText)
  has_rich_text :body

  # File attachment (via ActiveStorage)
  has_one_attached :attachment

  # Relationships
  belongs_to :room
  belongs_to :creator, class_name: "User"
  has_many :boosts, dependent: :destroy

  # Modules
  include Attachment          # File upload/thumbnail processing
  include Broadcasts          # Turbo Stream integration
  include Mentionee           # Extract mentioned users
  include Pagination          # Cursor-based pagination
  include Searchable          # FTS5 search indexing
end
```

**Message Types**:
1. **Text messages**: Rich text with formatting, links, mentions
2. **Attachment messages**: Files/images with optional caption
3. **Sound messages**: `/play soundname` triggers audio playback

**Key Methods**:
- `mentionees` - Extracts mentioned users from ActionText
- `page_around(id, limit)` - Cursor-based pagination
- `rebuild_search_index` - Rebuild FTS5 index
- Broadcast callbacks: `after_create_commit :broadcast_to_room`

**Idempotency**:
Messages are idempotent via `client_message_id`:
```ruby
validates :client_message_id, uniqueness: true, allow_nil: false
```

This prevents duplicate message posting on retry/refresh.

#### Membership

**Purpose**: Join table between User and Room with notification preferences and presence tracking.

**Schema**:
```ruby
# app/models/membership.rb
class Membership < ApplicationRecord
  # Attributes
  user_id: integer             # Member user
  room_id: integer             # Room
  involvement: integer         # Enum: invisible(0), nothing(1), mentions(2), everything(3)
  unread_at: datetime          # When membership became unread
  connections: integer         # WebSocket connection count (default: 0)
  connected_at: datetime       # Last connection timestamp

  # Relationships
  belongs_to :user
  belongs_to :room

  # Modules
  include Connectable          # Connection state management

  # Constants
  CONNECTION_TTL = 60.seconds  # Presence timeout window
end
```

**Involvement Levels** (notification preferences):
- `invisible` (0) - Hide room from sidebar completely
- `nothing` (1) - Show room but no notifications
- `mentions` (2) - Notify only on @mentions (default for open rooms)
- `everything` (3) - Notify on all messages (default for DMs)

**Presence Tracking**:
```ruby
# Connection state methods
connected     # Mark user as connected (increment connections)
disconnected  # Mark user as disconnected (decrement connections)
present?      # Check if connections > 0 and connected_at recent
refresh_connection  # Update connected_at timestamp
```

**Key Scopes**:
- `visible` - Not invisible
- `unread` - Has unread_at timestamp
- `connected` - Has active connections
- `without_direct_rooms` - Excludes DM rooms

**Read State Management**:
```ruby
membership.read   # Mark as read (clear unread_at)
membership.unread # Mark as unread (set unread_at)
```

### Supporting Models

#### Account

**Purpose**: Singleton configuration for the entire Campfire instance.

**Schema**:
```ruby
# app/models/account.rb
class Account < ApplicationRecord
  # Attributes
  join_code: string         # User registration code

  # Attachments
  has_one_attached :logo

  # Modules
  include Joinable          # Join code generation
end
```

**Usage**:
```ruby
account = Account.first  # Singleton - only one account per instance
account.regenerate_join_code!
```

#### Session

**Purpose**: User authentication sessions with security metadata.

**Schema**:
```ruby
# app/models/session.rb
class Session < ApplicationRecord
  # Attributes
  user_id: integer
  session_token: string     # Secure random token (indexed, unique)
  ip_address: string        # Connection IP
  user_agent: string        # Browser user agent
  created_at: datetime
  updated_at: datetime

  belongs_to :user
  has_secure_token :session_token
end
```

**Session Management**:
- Token stored in signed, HTTP-only cookie
- Activity tracked: `updated_at` refreshed on requests
- Same-site policy: `:lax` for CSRF protection

#### Push::Subscription

**Purpose**: Web Push notification endpoints and encryption keys.

**Schema**:
```ruby
# app/models/push/subscription.rb
class Push::Subscription < ApplicationRecord
  # Attributes
  user_id: integer
  endpoint: string          # Push service URL
  p256dh: string           # Client public key (ECDH)
  auth: string             # Client auth secret

  belongs_to :user

  validates :endpoint, uniqueness: { scope: [:p256dh, :auth] }
end
```

**Encryption**:
Web Push uses ECDH encryption with per-subscription keys:
- `p256dh` - Client's public key for ECDH key agreement
- `auth` - Shared authentication secret
- Payload encrypted before sending to push service

#### Webhook

**Purpose**: Bot webhook configuration for room integrations.

**Schema**:
```ruby
# app/models/webhook.rb
class Webhook < ApplicationRecord
  # Attributes
  room_id: integer
  user_id: integer          # Bot user
  url: string               # Webhook endpoint URL

  belongs_to :room
  belongs_to :user

  validates :url, presence: true, url: true
end
```

**Delivery Logic**:
- POST request with JSON payload
- 7-second timeout
- Triggered on message creation if:
  - Bot is mentioned in message
  - Message is in DM room containing bot
- Payload includes: user, room, message (HTML + plain text)

#### Boost

**Purpose**: Emoji reactions to messages.

**Schema**:
```ruby
# app/models/boost.rb
class Boost < ApplicationRecord
  # Attributes
  message_id: integer
  booster_id: integer       # User who reacted
  content: string           # Emoji (max 16 chars)

  belongs_to :message
  belongs_to :booster, class_name: "User"

  validates :content, length: { maximum: 16 }
  validates :booster_id, uniqueness: { scope: [:message_id, :content] }
end
```

#### Search

**Purpose**: User search history tracking.

**Schema**:
```ruby
# app/models/search.rb
class Search < ApplicationRecord
  # Attributes
  user_id: integer
  query: string             # Search term
  created_at: datetime

  belongs_to :user
end
```

## Authentication & Authorization

### Authentication Methods

#### 1. Session-Based (Primary)

**Flow**:
```
1. User submits login form
2. SessionsController validates credentials
3. Session record created with token
4. Signed cookie set with session_token
5. Subsequent requests validated via cookie
```

**Implementation** (`app/controllers/concerns/authentication/session_lookup.rb`):
```ruby
module Authentication::SessionLookup
  def current_session
    @current_session ||= Session.find_by(
      session_token: cookies.signed[:session_token]
    )
  end

  def current_user
    current_session&.user
  end
end
```

**Security Features**:
- Signed cookies prevent tampering
- HTTP-only flag prevents XSS cookie theft
- Same-site `:lax` mitigates CSRF
- Session tokens are cryptographically secure random strings

#### 2. Bot Authentication

**Format**: `{bot_id}-{bot_token}`

**Validation** (`app/models/user/bot.rb`):
```ruby
def self.authenticate_bot(bot_key)
  id, token = bot_key.split("-", 2)
  bot = where(role: :bot).find_by(id: id)
  bot if bot&.bot_token == token
end
```

**Usage**:
```bash
POST /rooms/123/1-abc123xyz/messages
Content-Type: application/json

{"body": "Hello from bot!"}
```

**Differences from User Sessions**:
- Stateless (no session record)
- CSRF protection disabled
- Access denied to browser-only routes
- Token exposed in URL (use HTTPS!)

### Authorization

#### Role-Based Access Control

**Roles** (enum in User model):
```ruby
enum role: { member: 0, administrator: 1, bot: 2 }
```

**Authorization Check** (`app/models/user/role.rb`):
```ruby
def can_administer?(record)
  administrator? ||           # Admins can do anything
  record.creator == self ||   # Creators can manage their records
  record.new_record?          # Anyone can create new records
end
```

**Controller Usage**:
```ruby
class RoomsController < ApplicationController
  before_action :ensure_can_administer, only: [:edit, :update, :destroy]

  def ensure_can_administer
    unless Current.user.can_administer?(@room)
      redirect_to @room, alert: "Not authorized"
    end
  end
end
```

#### Room Access Control

**Membership-Based Access**:
```ruby
# app/controllers/concerns/room_scoped.rb
module RoomScoped
  extend ActiveSupport::Concern

  included do
    before_action :set_room_and_membership
  end

  private

  def set_room_and_membership
    @room = Current.user.rooms.find(params[:room_id])
    @membership = Current.user.memberships.find_by(room: @room)
  rescue ActiveRecord::RecordNotFound
    redirect_to rooms_path, alert: "Room not found or access denied"
  end
end
```

This pattern ensures users can only access rooms they're members of.

### Security Features

1. **Password Security**:
   - BCrypt hashing via `has_secure_password`
   - Minimum length enforced (Rails validation)
   - Salted and stretched (BCrypt default: cost 12)

2. **Rate Limiting**:
   ```ruby
   # app/controllers/sessions_controller.rb
   rate_limit to: 10, within: 3.minutes, only: :create
   ```

3. **CSRF Protection**:
   - Enabled by default for all non-GET requests
   - Disabled for bot API endpoints
   - Token validated via Rails built-in mechanism

4. **Session Security**:
   - Signed cookies (tamper-proof)
   - HTTP-only (no JavaScript access)
   - Secure flag in production (HTTPS only)
   - Same-site `:lax` (CSRF mitigation)

5. **SQL Injection Prevention**:
   - ActiveRecord query builder (parameterized queries)
   - Never use string interpolation in queries

6. **XSS Prevention**:
   - HTML sanitization via ActionText whitelist
   - ERB auto-escaping in views
   - Content Security Policy headers (if configured)

## Real-time Features

### ActionCable Architecture

Campfire uses ActionCable for real-time WebSocket communication. Redis serves as the pub/sub backend.

**Connection Authentication** (`app/channels/application_cable/connection.rb`):
```ruby
module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    def connect
      self.current_user = find_verified_user
    end

    private

    def find_verified_user
      session = Session.find_by(
        session_token: cookies.signed[:session_token]
      )

      if session&.user
        session.user
      else
        reject_unauthorized_connection
      end
    end
  end
end
```

### Channels

#### RoomChannel (Base Channel)

**Purpose**: Base class for room-specific real-time features.

**Implementation** (`app/channels/room_channel.rb`):
```ruby
class RoomChannel < ApplicationCable::Channel
  def subscribed
    @room = current_user.rooms.find(params[:id])
    @membership = current_user.memberships.find_by(room: @room)

    stream_for @room if @membership
  rescue ActiveRecord::RecordNotFound
    reject
  end
end
```

**Inheritance**: PresenceChannel and TypingNotificationsChannel extend this.

#### PresenceChannel

**Purpose**: Track user online/offline status per room.

**Implementation** (`app/channels/presence_channel.rb`):
```ruby
class PresenceChannel < RoomChannel
  on_subscribe :present
  on_unsubscribe :absent

  def refresh(data)
    @membership.refresh_connection
    broadcast_read_rooms
  end

  private

  def present
    @membership.connected
    broadcast_read_rooms
  end

  def absent
    @membership.disconnected
  end

  def broadcast_read_rooms
    ActionCable.server.broadcast(
      "user_#{current_user.id}_reads",
      { room_id: @room.id }
    )
  end
end
```

**Client Interaction**:
```javascript
// Connect to presence channel
const subscription = consumer.subscriptions.create(
  { channel: "PresenceChannel", id: roomId },
  {
    connected() {
      // User marked as present
    },
    disconnected() {
      // User marked as absent
    },
    received(data) {
      // Handle broadcasts
    }
  }
);

// Refresh presence (called before CONNECTION_TTL expires)
subscription.perform("refresh");
```

**Connection Counting**:
- Multiple browser tabs/windows increment `connections` counter
- Prevents premature "away" status with multiple tabs open
- TTL refresh keeps users marked as present

#### TypingNotificationsChannel

**Purpose**: Show typing indicators in real-time.

**Implementation** (`app/channels/typing_notifications_channel.rb`):
```ruby
class TypingNotificationsChannel < RoomChannel
  def start(data)
    broadcast_to @room, {
      type: "typing",
      user: { id: current_user.id, name: current_user.name }
    }
  end

  def stop(data)
    broadcast_to @room, {
      type: "stopped_typing",
      user: { id: current_user.id }
    }
  end
end
```

**Client Usage**:
```javascript
// User starts typing
subscription.perform("start");

// User stops typing (after debounce)
subscription.perform("stop");
```

#### ReadRoomsChannel

**Purpose**: Notify user when they've read rooms on another device.

**Implementation** (`app/channels/read_rooms_channel.rb`):
```ruby
class ReadRoomsChannel < ApplicationCable::Channel
  def subscribed
    stream_from "user_#{current_user.id}_reads"
  end
end
```

**Use Case**:
User reads room on mobile → Desktop browser clears unread badge in real-time.

#### UnreadRoomsChannel

**Purpose**: Global broadcast when any room becomes unread.

**Implementation** (`app/channels/unread_rooms_channel.rb`):
```ruby
class UnreadRoomsChannel < ApplicationCable::Channel
  def subscribed
    stream_from "unread_rooms"
  end
end
```

**Broadcast Trigger** (`app/models/message/broadcasts.rb`):
```ruby
after_create_commit do
  if room.memberships.unread.exists?
    ActionCable.server.broadcast(
      "unread_rooms",
      { roomId: room.id }
    )
  end
end
```

#### HeartbeatChannel

**Purpose**: Keep WebSocket connections alive.

**Implementation** (`app/channels/heartbeat_channel.rb`):
```ruby
class HeartbeatChannel < ApplicationCable::Channel
  def subscribed
    stream_from "heartbeat"
  end
end
```

**Usage**: Prevents load balancers/proxies from closing idle connections.

### Turbo Streams Integration

Messages and updates use Turbo Streams for seamless UI updates:

**Message Broadcasting** (`app/models/message/broadcasts.rb`):
```ruby
module Message::Broadcasts
  extend ActiveSupport::Concern

  included do
    after_create_commit do
      broadcast_append_to(
        [room, :messages],
        target: "messages",
        partial: "messages/message",
        locals: { message: self }
      )
    end

    after_update_commit do
      broadcast_replace_to(
        [room, :messages],
        target: self,
        partial: "messages/message",
        locals: { message: self }
      )
    end

    after_destroy_commit do
      broadcast_remove_to [room, :messages]
    end
  end
end
```

**Rendering**:
- Turbo Streams send HTML fragments over WebSocket
- Browser automatically updates DOM based on action (append, replace, remove)
- No JavaScript needed for basic message updates

## Background Jobs

### Job Queue Configuration

**Resque** (Redis-backed queue) with **resque-pool** for process management.

**Configuration** (`config/initializers/resque.rb`):
```ruby
Resque.redis = Redis.new(url: ENV["REDIS_URL"] || "redis://localhost:6379")
Resque.redis.namespace = "campfire:resque"
```

**Worker Pool** (`config/resque-pool.yml`):
```yaml
production:
  "*": 2  # Run 2 workers processing all queues

development:
  "*": 1
```

### Job Classes

#### Room::PushMessageJob

**Purpose**: Send Web Push notifications for new messages.

**Trigger**: `after_create_commit` callback on Message model.

**Implementation** (`app/jobs/room/push_message_job.rb`):
```ruby
class Room::PushMessageJob < ApplicationJob
  queue_as :default

  def perform(message)
    Room::MessagePusher.new(message).deliver
  end
end
```

**Delivery Logic** (`app/models/room/message_pusher.rb`):
```ruby
class Room::MessagePusher
  def initialize(message)
    @message = message
    @room = message.room
    @creator = message.creator
  end

  def deliver
    subscriptions.find_each do |subscription|
      WebPush::Pool.push(
        endpoint: subscription.endpoint,
        message: payload(subscription.user),
        p256dh: subscription.p256dh,
        auth: subscription.auth,
        vapid: vapid_details
      )
    end
  end

  private

  def subscriptions
    # Filter by:
    # 1. Room membership
    # 2. Involvement level (everything or mentions)
    # 3. Disconnected users only (don't notify active users)
    # 4. For mentions: only mentioned users

    scope = @room.users.joins(:push_subscriptions, :memberships)
      .where(memberships: { room: @room })
      .where.not(id: @creator.id)  # Don't notify sender
      .merge(Membership.disconnected)  # Only offline users

    if @message.mentionees.any?
      # For mentions: users with "mentions" or "everything"
      scope.where(id: @message.mentionees)
        .where(memberships: { involvement: [:mentions, :everything] })
    else
      # For regular messages: only users with "everything"
      scope.where(memberships: { involvement: :everything })
    end.distinct
  end

  def payload(user)
    JSON.generate({
      title: "#{@creator.name} in #{@room.name}",
      body: @message.body.to_plain_text.truncate(100),
      icon: @creator.avatar_url,
      url: room_message_url(@room, @message)
    })
  end
end
```

**Key Features**:
- Async delivery (doesn't block message posting)
- Filtered by user notification preferences
- Only notifies disconnected users (avoids duplicate notifications)
- Respects mention-based notification settings

#### Bot::WebhookJob

**Purpose**: Deliver webhook payloads to bot integrations.

**Trigger**: `after_create_commit` callback on Message model (if bots involved).

**Implementation** (`app/jobs/bot/webhook_job.rb`):
```ruby
class Bot::WebhookJob < ApplicationJob
  queue_as :default

  discard_on ActiveJob::DeserializationError

  def perform(webhook, message)
    webhook.deliver(message)
  end
end
```

**Webhook Delivery** (`app/models/webhook.rb`):
```ruby
class Webhook < ApplicationRecord
  TIMEOUT = 7.seconds

  def deliver(message)
    response = HTTP.timeout(TIMEOUT).post(url, json: payload(message))

    if response.status.success? && response.body.present?
      handle_response(response.body, message.room)
    end
  rescue HTTP::TimeoutError
    Rails.logger.warn("Webhook timeout: #{url}")
  end

  private

  def payload(message)
    {
      user: {
        id: message.creator.id,
        name: message.creator.name,
        email: message.creator.email_address
      },
      room: {
        id: message.room.id,
        name: message.room.name,
        type: message.room.type
      },
      message: {
        id: message.id,
        body_html: message.body.to_s,
        body_text: message.body.to_plain_text,
        created_at: message.created_at
      }
    }
  end

  def handle_response(body, room)
    data = JSON.parse(body)

    # Bot can respond with text or attachment
    if data["text"].present?
      Message.create!(
        room: room,
        creator: user,  # Bot user
        body: data["text"]
      )
    elsif data["attachment_url"].present?
      # Download and attach file
      # ...
    end
  rescue JSON::ParserError
    Rails.logger.warn("Invalid JSON response from webhook: #{url}")
  end
end
```

**Webhook Triggering Logic** (`app/models/message.rb`):
```ruby
after_create_commit do
  room.webhooks.each do |webhook|
    bot = webhook.user

    # Trigger webhook if:
    # 1. Bot is mentioned in message, OR
    # 2. Message is in direct room containing bot
    if mentionees.include?(bot) || (room.direct? && room.users.include?(bot))
      Bot::WebhookJob.perform_later(webhook, self)
    end
  end
end
```

## Notification System

### Web Push Implementation

Campfire uses the W3C Web Push API with VAPID authentication.

#### Subscription Flow

**1. Client subscribes to push notifications:**

```javascript
// app/javascript/controllers/push_subscription_controller.js
async subscribe() {
  const registration = await navigator.serviceWorker.ready;

  const subscription = await registration.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: this.vapidPublicKey
  });

  // Send subscription to server
  await fetch("/push_subscriptions", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      endpoint: subscription.endpoint,
      keys: {
        p256dh: base64encode(subscription.getKey("p256dh")),
        auth: base64encode(subscription.getKey("auth"))
      }
    })
  });
}
```

**2. Server stores subscription** (`app/controllers/push_subscriptions_controller.rb`):

```ruby
def create
  Current.user.push_subscriptions.create!(
    endpoint: params[:endpoint],
    p256dh: params[:keys][:p256dh],
    auth: params[:keys][:auth]
  )
end
```

#### Sending Notifications

**VAPID Configuration** (`config/initializers/web_push.rb`):
```ruby
WebPush.vapid_config = {
  subject: "mailto:admin@example.com",
  public_key: ENV["VAPID_PUBLIC_KEY"],
  private_key: ENV["VAPID_PRIVATE_KEY"]
}
```

**Async Delivery with Thread Pool**:
```ruby
# lib/web_push/pool.rb
module WebPush
  class Pool
    POOL_SIZE = 5

    def self.push(endpoint:, message:, p256dh:, auth:, vapid:)
      pool.post do
        WebPush.payload_send(
          endpoint: endpoint,
          message: message,
          p256dh: p256dh,
          auth: auth,
          vapid: vapid
        )
      rescue WebPush::InvalidSubscription
        # Subscription expired, delete it
        Push::Subscription.find_by(endpoint: endpoint)&.destroy
      end
    end

    def self.pool
      @pool ||= Concurrent::ThreadPoolExecutor.new(
        min_threads: 1,
        max_threads: POOL_SIZE,
        max_queue: 100
      )
    end
  end
end
```

#### Notification Filtering

Users receive push notifications based on:

1. **Involvement Level**:
   - `everything` → All messages in room
   - `mentions` → Only @mentions
   - `nothing` / `invisible` → No notifications

2. **Connection Status**:
   - Only send to disconnected users
   - Avoids duplicate notifications for active users

3. **Mention Filtering**:
   - If message has mentions: only notify mentioned users
   - Respects involvement level (must have `mentions` or `everything`)

4. **Self-notification Prevention**:
   - Never notify message sender

**Implementation**: See `Room::MessagePusher` in Background Jobs section.

## Bot Integration

### Bot User Model

Bots are User records with `role: :bot`:

```ruby
bot = User.create!(
  name: "Deploy Bot",
  email_address: "deploy-bot@example.com",
  role: :bot
)

bot.regenerate_bot_token  # Generates secure random token
bot.bot_key  # Returns "{id}-{token}" for API authentication
```

### Bot API

#### Authentication

**Format**: Include bot_key in URL path:
```
POST /rooms/{room_id}/{bot_key}/messages
```

**Example**:
```bash
curl -X POST https://chat.example.com/rooms/42/7-abc123xyz/messages \
  -H "Content-Type: application/json" \
  -d '{
    "body": "Deploy completed successfully!",
    "client_message_id": "deploy-2024-01-15-001"
  }'
```

**Controller Implementation** (`app/controllers/messages/by_bots_controller.rb`):
```ruby
class Messages::ByBotsController < ApplicationController
  skip_before_action :verify_authenticity_token  # Disable CSRF for API
  before_action :authenticate_bot

  def create
    @message = @room.messages.create!(
      creator: @bot,
      body: params[:body],
      client_message_id: params[:client_message_id]
    )

    render json: { id: @message.id }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: e.message }, status: :unprocessable_entity
  end

  private

  def authenticate_bot
    @bot = User.authenticate_bot(params[:bot_key])
    @room = @bot.rooms.find(params[:room_id])

    head :forbidden unless @bot && @room
  end
end
```

#### Idempotency

Use `client_message_id` to prevent duplicate messages:
```bash
# First POST - creates message
curl -X POST .../messages -d '{"body": "Hello", "client_message_id": "abc"}'
# Response: 201 Created

# Retry - returns existing message
curl -X POST .../messages -d '{"body": "Hello", "client_message_id": "abc"}'
# Response: 422 Unprocessable Entity (or returns existing message ID)
```

### Webhook Integration

#### Creating Webhooks

Webhooks are created through the admin UI or API:
```ruby
webhook = room.webhooks.create!(
  user: bot_user,
  url: "https://bot.example.com/webhooks/campfire"
)
```

#### Webhook Payload

When a webhook is triggered, the bot receives:
```json
{
  "user": {
    "id": 123,
    "name": "Alice Smith",
    "email": "alice@example.com"
  },
  "room": {
    "id": 42,
    "name": "Engineering",
    "type": "Rooms::Open"
  },
  "message": {
    "id": 9876,
    "body_html": "<div>@deploybot please deploy <strong>v2.3.1</strong></div>",
    "body_text": "@deploybot please deploy v2.3.1",
    "created_at": "2024-01-15T10:30:00Z"
  }
}
```

#### Bot Response

The bot can respond with JSON:

**Text response:**
```json
{
  "text": "Deploying v2.3.1 to production..."
}
```

**Attachment response:**
```json
{
  "attachment_url": "https://bot.example.com/reports/deploy-log.txt",
  "text": "Deployment complete! See attached log."
}
```

**Response Handling** (`app/models/webhook.rb`):
```ruby
def handle_response(body, room)
  data = JSON.parse(body)

  message_params = { room: room, creator: user }

  if data["text"].present?
    message_params[:body] = data["text"]
  end

  message = Message.create!(message_params)

  if data["attachment_url"].present?
    # Download and attach file asynchronously
    AttachmentDownloadJob.perform_later(message, data["attachment_url"])
  end
end
```

#### Webhook Triggers

Webhooks fire when:

1. **Bot is @mentioned in a room message**:
   ```
   User: "@deploybot deploy staging"
   → Webhook sent to deploybot's webhook URL
   ```

2. **Any message in a direct message room containing the bot**:
   ```
   User creates DM with bot
   User: "What's the status?"
   → Webhook sent to bot
   ```

**Implementation** (`app/models/message.rb`):
```ruby
after_create_commit do
  room.webhooks.includes(:user).each do |webhook|
    bot = webhook.user

    should_trigger = mentionees.include?(bot) ||
                     (room.direct? && room.users.include?(bot))

    Bot::WebhookJob.perform_later(webhook, self) if should_trigger
  end
end
```

### Bot Best Practices

1. **Use client_message_id**: Prevent duplicate messages on retry
2. **Validate webhook signatures**: Add HMAC validation for security (custom implementation)
3. **Respond quickly**: 7-second timeout enforced
4. **Handle mentions gracefully**: Parse `body_text` to extract commands
5. **Use rate limiting**: Avoid flooding rooms with bot messages
6. **Log webhook failures**: Monitor delivery success rates
7. **Secure bot tokens**: Treat like passwords, rotate regularly

## Search Implementation

### Full-Text Search with SQLite FTS5

Campfire uses SQLite's FTS5 (Full-Text Search 5) extension for message search.

#### FTS5 Virtual Table

**Migration** (`db/migrate/...create_messages_fts.rb`):
```ruby
def change
  execute <<-SQL
    CREATE VIRTUAL TABLE messages_fts USING fts5(
      id UNINDEXED,
      body,
      content=messages,
      content_rowid=id
    );
  SQL

  # Triggers to keep FTS index in sync
  execute <<-SQL
    CREATE TRIGGER messages_fts_insert AFTER INSERT ON messages BEGIN
      INSERT INTO messages_fts(id, body)
      VALUES (new.id, (SELECT body FROM action_text_rich_texts WHERE record_type='Message' AND record_id=new.id));
    END;
  SQL

  execute <<-SQL
    CREATE TRIGGER messages_fts_update AFTER UPDATE ON messages BEGIN
      UPDATE messages_fts
      SET body = (SELECT body FROM action_text_rich_texts WHERE record_type='Message' AND record_id=new.id)
      WHERE id = new.id;
    END;
  SQL

  execute <<-SQL
    CREATE TRIGGER messages_fts_delete AFTER DELETE ON messages BEGIN
      DELETE FROM messages_fts WHERE id = old.id;
    END;
  SQL
end
```

#### Search Implementation

**Model** (`app/models/message/searchable.rb`):
```ruby
module Message::Searchable
  extend ActiveSupport::Concern

  included do
    scope :search, ->(query) {
      return all if query.blank?

      # Sanitize query for FTS5
      sanitized = query.gsub(/[^\w\s]/, '').split.map { |term|
        "#{term}*"  # Prefix matching
      }.join(" ")

      joins(<<-SQL)
        INNER JOIN messages_fts ON messages_fts.id = messages.id
      SQL
      .where("messages_fts MATCH ?", sanitized)
      .order("rank")  # FTS5 relevance ranking
    }
  end

  class_methods do
    def rebuild_search_index
      execute("DELETE FROM messages_fts")

      Message.find_each do |message|
        execute(<<-SQL)
          INSERT INTO messages_fts(id, body)
          VALUES (#{message.id}, '#{sanitize_sql(message.body.to_plain_text)}')
        SQL
      end
    end
  end
end
```

**Controller** (`app/controllers/searches_controller.rb`):
```ruby
class SearchesController < ApplicationController
  def show
    @query = params[:q]

    # Search across user's accessible rooms
    @messages = Message
      .joins(:room)
      .merge(Current.user.rooms)
      .search(@query)
      .includes(:creator, :room)
      .limit(50)

    # Track search history
    Current.user.searches.create!(query: @query) if @query.present?
  end
end
```

#### Search Features

**Supported**:
- Prefix matching: `deploy*` matches "deploy", "deployment", "deploying"
- Multiple terms: `deploy production` (AND logic)
- Relevance ranking (BM25 algorithm)
- Stemming: Language-specific (English by default)
- Fast: Indexed for O(log n) lookups

**Limitations**:
- No phrase search with quotes
- No field-specific search (e.g., `from:alice`)
- No date range filtering in FTS (use SQL WHERE)
- English-optimized tokenizer

#### Rebuilding Index

```ruby
# Rails console or rake task
Message.rebuild_search_index
```

**When to rebuild**:
- After database import/migration
- If search results seem stale
- After changing FTS5 configuration

## File Storage

### ActiveStorage Configuration

**Storage Services** (`config/storage.yml`):
```yaml
local:
  service: Disk
  root: <%= Rails.root.join("storage") %>

production:
  service: Disk
  root: /rails/storage

amazon:
  service: S3
  access_key_id: <%= ENV["AWS_ACCESS_KEY_ID"] %>
  secret_access_key: <%= ENV["AWS_SECRET_ACCESS_KEY"] %>
  region: us-east-1
  bucket: campfire-<%= ENV["RAILS_ENV"] %>
```

**Active Service** (`config/environments/production.rb`):
```ruby
config.active_storage.service = :local  # or :amazon
```

### Message Attachments

**Model** (`app/models/message/attachment.rb`):
```ruby
module Message::Attachment
  extend ActiveSupport::Concern

  included do
    has_one_attached :attachment do |attachable|
      attachable.variant :thumb, resize_to_limit: [400, 400]
      attachable.variant :large, resize_to_limit: [1200, 800]
    end

    validates :attachment,
      content_type: {
        in: %w[
          image/png image/jpg image/jpeg image/gif
          video/mp4 video/quicktime
          application/pdf
          text/plain
        ],
        message: "must be an image, video, PDF, or text file"
      },
      size: { less_than: 100.megabytes }
  end

  def image?
    attachment.content_type.start_with?("image/")
  end

  def video?
    attachment.content_type.start_with?("video/")
  end
end
```

### Image Processing

**Variants**:
- `thumb` - 400x400px for sidebar previews
- `large` - 1200x800px for lightbox/modals

**Processing Library**:
- Configured to use libvips (faster than ImageMagick)
- Automatic format conversion (WebP where supported)
- Lazy processing: variants generated on first access

**View** (`app/views/messages/_attachment.html.erb`):
```erb
<% if message.image? %>
  <%= link_to rails_blob_path(message.attachment, disposition: "inline"),
              target: "_blank", data: { turbo: false } do %>
    <%= image_tag message.attachment.variant(:large),
                  class: "message-attachment" %>
  <% end %>
<% elsif message.video? %>
  <%= video_tag rails_blob_path(message.attachment, disposition: "inline"),
                controls: true,
                preload: "metadata",
                class: "message-attachment" %>
<% else %>
  <%= link_to message.attachment.filename,
              rails_blob_path(message.attachment, disposition: "attachment") %>
<% end %>
```

### User Avatars

**Model** (`app/models/user/avatar.rb`):
```ruby
module User::Avatar
  extend ActiveSupport::Concern

  included do
    has_one_attached :avatar do |attachable|
      attachable.variant :thumb, resize_to_fill: [100, 100]
      attachable.variant :small, resize_to_fill: [50, 50]
    end
  end

  def avatar_url(size: :thumb)
    if avatar.attached?
      Rails.application.routes.url_helpers.rails_representation_url(
        avatar.variant(size),
        only_path: true
      )
    else
      # Default avatar
      ActionController::Base.helpers.asset_path("default-avatar.png")
    end
  end
end
```

### Account Logo

**Model** (`app/models/account.rb`):
```ruby
class Account < ApplicationRecord
  has_one_attached :logo

  def logo_url
    logo.attached? ? Rails.application.routes.url_helpers.rails_blob_path(logo, only_path: true) : nil
  end
end
```

**Usage**: Displayed on login page and header.

### Direct Upload (Optional Enhancement)

For large files, consider enabling direct upload to S3:

**JavaScript** (not implemented by default):
```javascript
// Direct upload bypasses Rails server
import { DirectUpload } from "@rails/activestorage";

function uploadFile(file) {
  const upload = new DirectUpload(
    file,
    "/rails/active_storage/direct_uploads"
  );

  upload.create((error, blob) => {
    if (error) {
      console.error(error);
    } else {
      // Attach blob.signed_id to message form
      hiddenInput.value = blob.signed_id;
    }
  });
}
```

**Benefit**: Reduces server load for large file uploads.

## Performance Considerations

### Database Optimization

#### Indexes

**Critical Indexes**:
```ruby
# Memberships
add_index :memberships, [:user_id, :room_id], unique: true
add_index :memberships, [:room_id, :created_at]
add_index :memberships, [:user_id, :unread_at]
add_index :memberships, :connected_at

# Messages
add_index :messages, [:room_id, :created_at]
add_index :messages, :creator_id
add_index :messages, :client_message_id, unique: true

# Users
add_index :users, :email_address, unique: true
add_index :users, :role

# Push Subscriptions
add_index :push_subscriptions, [:endpoint, :p256dh, :auth], unique: true, name: "index_push_subscriptions_unique"
```

#### Query Optimization

**N+1 Prevention**:
```ruby
# Bad: N+1 queries
@room.messages.each do |message|
  message.creator.name  # Queries for each message
end

# Good: Eager loading
@room.messages.includes(:creator).each do |message|
  message.creator.name  # No additional queries
end
```

**Pagination**:
```ruby
# Cursor-based pagination (efficient for large datasets)
def page_around(id, limit: 50)
  before = where("id < ?", id).order(id: :desc).limit(limit / 2)
  after = where("id >= ?", id).order(id: :asc).limit(limit / 2)

  (before.reverse + after)
end

# Better than offset-based:
# where(...).offset(1000).limit(50)  # Slow on large tables
```

### Caching Strategy

#### Fragment Caching

**Message Caching** (`app/views/messages/_message.html.erb`):
```erb
<% cache message do %>
  <div class="message" id="<%= dom_id(message) %>">
    <!-- Message content -->
  </div>
<% end %>
```

**Cache Key**: Automatically includes `message.cache_key_with_version`
- Format: `messages/123-20240115103000000000`
- Invalidates on update

#### Russian Doll Caching

**Nested Caching** (`app/views/rooms/show.html.erb`):
```erb
<% cache [@room, "messages"] do %>
  <% @messages.each do |message| %>
    <% cache message do %>
      <%= render message %>
    <% end %>
  <% end %>
<% end %>
```

**Benefit**: Only re-render changed messages, not entire list.

#### HTTP Caching

**ETags**:
```ruby
# app/controllers/rooms_controller.rb
def show
  fresh_when(@room)  # Sets ETag header
end
```

**Browser caching**: Returns 304 Not Modified if content unchanged.

### Connection Pooling

#### Database Connections

**Configuration** (`config/database.yml`):
```yaml
production:
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  timeout: 5000
```

**Puma Threads**: Match database pool size to Puma threads:
```ruby
# config/puma.rb
threads_count = ENV.fetch("RAILS_MAX_THREADS") { 5 }
threads threads_count, threads_count
```

#### Redis Connections

**Resque** (`config/initializers/resque.rb`):
```ruby
Resque.redis = ConnectionPool.new(size: 5, timeout: 5) do
  Redis.new(url: ENV["REDIS_URL"])
end
```

**ActionCable** (`config/cable.yml`):
```yaml
production:
  adapter: redis
  url: redis://localhost:6379
  channel_prefix: campfire_production
```

### Background Job Performance

#### Job Prioritization

**Multiple Queues** (future enhancement):
```ruby
class CriticalJob < ApplicationJob
  queue_as :critical
end

class DefaultJob < ApplicationJob
  queue_as :default
end
```

**Worker Configuration** (`config/resque-pool.yml`):
```yaml
production:
  critical: 2  # 2 workers for critical jobs
  default: 3   # 3 workers for default jobs
```

#### Batch Processing

**Bulk Notifications** (current implementation uses thread pool):
```ruby
# Instead of N jobs for N users:
PushMessageJob.perform_later(message)  # Single job

# Inside job, use thread pool:
WebPush::Pool.push(...)  # Concurrent delivery
```

### Frontend Performance

#### Asset Optimization

**Propshaft** (modern asset pipeline):
- No Sprockets compilation overhead
- Direct file serving with fingerprinting
- CDN-ready with cache headers

**ImportMaps**:
- No build step for JavaScript
- HTTP/2 multiplexing eliminates need for bundling
- Faster development iteration

#### Turbo Optimization

**Turbo Drive**:
- Preserves DOM between page transitions
- Only replaces `<body>` content
- Keeps JavaScript state alive

**Turbo Frames**:
```erb
<%= turbo_frame_tag "messages" do %>
  <% @messages.each do |message| %>
    <%= render message %>
  <% end %>
<% end %>
```

**Benefit**: Only updates message frame, not entire page.

#### WebSocket Connection Management

**Single Connection**:
- ActionCable multiplexes all channels over one WebSocket
- Reduces connection overhead vs. multiple WebSockets

**Automatic Reconnection**:
- ActionCable handles reconnection on network issues
- Subscriptions automatically re-established

### Monitoring Recommendations

**Key Metrics**:
1. **Database**:
   - Query time (P50, P95, P99)
   - Connection pool usage
   - SQLite database size

2. **Redis**:
   - Memory usage
   - Resque queue depth
   - ActionCable pub/sub latency

3. **Jobs**:
   - Job processing time
   - Failed job count
   - Queue latency (time to process)

4. **Web Push**:
   - Delivery success rate
   - Invalid subscription count
   - Thread pool queue size

5. **Web Server**:
   - Request throughput (req/s)
   - Response time
   - Active WebSocket connections

**Tools**:
- Sentry: Error tracking
- Redis CLI: `redis-cli INFO` for stats
- Resque Web UI: Job monitoring
- Rails instrumentation: `ActiveSupport::Notifications`

---

## Summary

Campfire's architecture balances simplicity with modern real-time features:

- **SQLite** provides a robust, zero-config database with excellent full-text search
- **ActionCable** delivers real-time updates without complex infrastructure
- **Resque** handles background jobs reliably with Redis
- **Turbo** enables reactive UI updates with minimal JavaScript
- **Web Push** provides native notifications without third-party services

This design prioritizes:
1. **Ease of deployment**: Docker image includes everything
2. **Maintainability**: Rails conventions reduce complexity
3. **Scalability**: Optimized for single-server to small cluster
4. **Developer experience**: Modern stack with fast iteration

For larger deployments, the architecture supports:
- External Redis for caching/jobs
- S3-compatible storage for files
- Multiple Resque workers for background processing
- Load balancing with sticky sessions (WebSocket support)
