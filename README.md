# Campfire

Campfire is a modern, self-hosted web-based chat application built with Ruby on Rails. It's designed for team collaboration with real-time messaging, file sharing, and rich integrations.

## Features

### Core Functionality
- **Multiple room types** with granular access controls:
  - Open rooms (public, auto-join for all users)
  - Closed rooms (invitation-only)
  - Direct messages (1-on-1 or group conversations)
- **Real-time messaging** powered by ActionCable (WebSockets)
- **Rich text formatting** with ActionText
- **File attachments** with automatic image/video previews
- **Full-text search** across all messages (SQLite FTS5)
- **@mentions** with notifications
- **Message reactions** (emoji boosts)
- **Typing indicators** and presence tracking

### Notifications
- **Web Push notifications** (standards-based browser notifications)
- **Customizable notification preferences** per room:
  - Everything (all messages)
  - Mentions only (only when @mentioned)
  - Nothing (mute notifications)
  - Invisible (hide room from sidebar)

### Integrations
- **Bot API** with webhook support
- **Bot webhooks** triggered by mentions or direct messages
- Automatic bot responses with text or file attachments
- Idempotent message posting with client IDs

### Security & Access Control
- Role-based access (member, administrator, bot)
- Session-based authentication with secure cookies
- BCrypt password hashing
- Rate-limited login attempts
- User deactivation (soft delete)
- CSRF protection

## Technology Stack

- **Framework**: Ruby on Rails (main branch)
- **Database**: SQLite3 with FTS5 full-text search
- **Cache/Jobs**: Redis with Resque
- **Web Server**: Puma with Thruster
- **Real-time**: ActionCable (WebSockets)
- **Frontend**: Turbo, Stimulus, ImportMaps
- **Rich Text**: ActionText with Trix editor
- **File Storage**: ActiveStorage (local or S3-compatible)
- **Notifications**: Web Push API with VAPID

## Quick Start

### Running in Development

```bash
# Install dependencies and setup database
bin/setup

# Start the Rails server
bin/rails server

# Visit http://localhost:3000
```

On first launch, you'll be guided through creating an admin account.

### Running Tests

```bash
# Run all tests
bin/rails test

# Run specific test file
bin/rails test test/models/user_test.rb

# Run system tests
bin/rails test:system
```

## Deploying with Docker

Campfire's Docker image is a complete, production-ready deployment including:
- Web application (Puma)
- Background job processing (Resque)
- Redis (caching and jobs)
- Automatic SSL via Let's Encrypt
- Static file serving with Thruster

### Basic Docker Deployment

```bash
# Build the image
docker build -t campfire .

# Run the container
docker run \
  --publish 80:80 --publish 443:443 \
  --restart unless-stopped \
  --volume campfire:/rails/storage \
  --env SECRET_KEY_BASE=$YOUR_SECRET_KEY_BASE \
  --env VAPID_PUBLIC_KEY=$YOUR_PUBLIC_KEY \
  --env VAPID_PRIVATE_KEY=$YOUR_PRIVATE_KEY \
  --env TLS_DOMAIN=chat.example.com \
  campfire
```

**Important**: The volume `/rails/storage` persists your database and uploaded files. Back it up regularly!

## Configuration

### Environment Variables

#### Required
- `SECRET_KEY_BASE` - Rails secret for session encryption (generate with `bin/rails secret`)

#### SSL/TLS
- `TLS_DOMAIN` - Enable automatic SSL via Let's Encrypt for this domain
- `DISABLE_SSL` - Set to any value to serve over plain HTTP (not recommended for production)

#### Web Push Notifications
- `VAPID_PUBLIC_KEY` - VAPID public key for Web Push
- `VAPID_PRIVATE_KEY` - VAPID private key for Web Push

Generate a VAPID keypair:
```bash
# In Docker container
docker exec -it <container_id> /script/admin/create-vapid-key

# In development
bin/rails runner "puts WebPush.generate_key.inspect"
```

#### Error Tracking
- `SENTRY_DSN` - Sentry DSN for error reporting (optional)

#### Redis
- `REDIS_URL` - Redis connection URL (default: `redis://localhost:6379`)

#### File Storage
- Configure S3-compatible storage in `config/storage.yml` if needed
- Set `RAILS_ENV=production` to use production storage configuration

## Architecture Overview

### Models

**Core Models:**
- `User` - User accounts with roles (member, administrator, bot)
- `Room` - Chat rooms (Single Table Inheritance: Open, Closed, Direct)
- `Message` - Chat messages with rich text and attachments
- `Membership` - User-room relationships with notification preferences

**Supporting Models:**
- `Account` - Single instance configuration (join codes, branding)
- `Session` - User authentication sessions
- `Boost` - Message reactions (emoji)
- `Push::Subscription` - Web Push notification endpoints
- `Webhook` - Bot webhook configurations

### Real-time Features

**ActionCable Channels:**
- `RoomChannel` - Base channel for room-specific streams
- `PresenceChannel` - User connection tracking
- `TypingNotificationsChannel` - Typing indicators
- `ReadRoomsChannel` - Read room state updates
- `UnreadRoomsChannel` - Unread room notifications
- `HeartbeatChannel` - Connection keep-alive

### Background Jobs

- `Room::PushMessageJob` - Sends Web Push notifications
- `Bot::WebhookJob` - Delivers webhook payloads to bots

Jobs are processed asynchronously via Resque (Redis-backed queue).

### Bot Integration

Bots can post messages via the API:

```bash
# Post a message as a bot
curl -X POST https://chat.example.com/rooms/123/bot_key/messages \
  -H "Content-Type: application/json" \
  -d '{"body": "Hello from bot!", "client_message_id": "unique-id"}'
```

Bot authentication uses `bot_key` format: `{bot_id}-{bot_token}`

Bots receive webhooks when:
- Mentioned in a room message
- Any message in a direct message room with the bot

Webhook payload includes:
- User details (name, email)
- Room details (name, type)
- Message content (HTML and plain text)

## Development Guide

### Prerequisites

- Ruby 3.3+ (see `.ruby-version`)
- Node.js (for JavaScript dependencies)
- Redis (for caching and background jobs)
- SQLite3 (included on most systems)

### Setup

```bash
# Clone the repository
git clone https://github.com/basecamp/once-campfire.git
cd once-campfire

# Install dependencies
bundle install

# Setup database
bin/rails db:setup

# Start development server
bin/dev
```

The `bin/dev` script starts:
- Rails server (Puma)
- Background job worker (Resque)
- Asset watching (if configured)

### Code Organization

```
app/
├── models/          # ActiveRecord models
├── controllers/     # Request handlers
├── channels/        # ActionCable WebSocket channels
├── jobs/            # Background jobs (Resque)
├── views/           # ERB templates and Turbo Streams
├── javascript/      # Stimulus controllers
└── assets/          # CSS and static assets

test/
├── models/          # Model unit tests
├── controllers/     # Controller integration tests
├── channels/        # ActionCable tests
├── system/          # End-to-end browser tests
└── fixtures/        # Test data
```

### Testing

```bash
# Run all tests
bin/rails test

# Run with coverage
COVERAGE=1 bin/rails test

# Run specific test
bin/rails test test/models/user_test.rb:25

# Run system tests
bin/rails test:system

# Lint with Rubocop
bundle exec rubocop

# Security scan with Brakeman
bundle exec brakeman
```

### Database

Campfire uses SQLite3 with:
- Full-text search via FTS5 extension
- Transactional DDL for migrations
- Optimized for single-server deployments

To reset the database:
```bash
bin/rails db:reset
```

### Debugging

```bash
# Launch Rails console
bin/rails console

# Launch console for specific environment
bin/rails console production

# Run database migrations
bin/rails db:migrate

# View routes
bin/rails routes
```

## Deployment Considerations

### Single-Tenant Architecture

Campfire is designed as a single-tenant application:
- One instance = one organization/team
- Public rooms are accessible to all users in that instance
- To support multiple isolated teams, deploy separate instances

### Scaling

For single-machine deployments, the Docker image is optimized and includes everything needed.

For larger deployments, consider:
- Separate Redis instance for caching and jobs
- S3-compatible storage for file attachments
- Multiple Resque workers for background jobs
- Load balancer with sticky sessions (for WebSocket support)

### Backups

**Critical data to backup:**
- `/rails/storage` volume (contains SQLite database and uploaded files)
- Environment variables (especially `SECRET_KEY_BASE` and VAPID keys)

**Backup strategy:**
```bash
# Backup storage volume
docker run --rm --volumes-from <container> -v $(pwd):/backup ubuntu tar czf /backup/campfire-backup.tar.gz /rails/storage

# Restore
docker run --rm --volumes-from <container> -v $(pwd):/backup ubuntu tar xzf /backup/campfire-backup.tar.gz -C /
```

### Monitoring

Monitor these metrics:
- Resque queue size (background job backlog)
- Redis memory usage
- SQLite database size
- Disk space (for file attachments)
- Web Push delivery failures

### Security Best Practices

1. **Always use HTTPS** in production (set `TLS_DOMAIN`)
2. **Keep `SECRET_KEY_BASE` secret** and never commit it to version control
3. **Regularly update** dependencies for security patches
4. **Enable Sentry** or similar error tracking to catch issues
5. **Backup regularly** and test restore procedures
6. **Rate limit** is enabled for login attempts (10 per 3 minutes)
7. **Review user permissions** regularly using admin panel

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on:
- Reporting bugs
- Suggesting features
- Submitting pull requests
- Code standards and testing requirements

**Quick summary:**
- Open a discussion before creating issues or PRs
- Issues are reserved for agreed-upon, actionable tasks
- Follow existing code style (enforced by Rubocop)
- Add tests for new features
- Keep PRs focused and well-described

## License

Campfire is released under the [MIT License](MIT-LICENSE).

## Support & Community

- **GitHub Discussions**: https://github.com/basecamp/once-campfire/discussions
- **Issue Tracker**: https://github.com/basecamp/once-campfire/issues
- **Documentation**: See `ARCHITECTURE.md` for detailed technical documentation

## Worth Noting

- **First-time setup**: You'll create an admin account on first launch
- **Password resets**: The admin email is shown on the login page for users who need password help
- **User management**: Admins can create users, manage rooms, and configure webhooks
- **Join codes**: Generate join codes to allow new users to self-register
- **Sounds**: Use `/play soundname` in messages to trigger sound effects
