# Commands & Guidelines for Claude Code - Campfire

## Tech Stack Overview
- Rails (edge - main branch)
- SQLite3 for database
- Redis for caching and Action Cable
- Resque for background job processing
- Hotwire (Turbo Rails + Stimulus)
- Importmap for JavaScript dependencies
- Web Push for notifications

## Development Setup

### Initial Setup
- `bin/setup`: Install dependencies and setup database
- `bin/rails server`: Start the Rails development server (port 3000)
- `bin/dev`: Start development server (if available)

### Background Jobs
- `bin/rails resque:work`: Start Resque worker for background jobs
- Jobs are used for: notifications, file processing, async operations

## Testing

### Running Tests
- `bin/rails test`: Run all tests
- `bin/rails test test/models/user_test.rb`: Run specific test file
- `bin/rails test test/models/user_test.rb:21`: Run specific test at line 21
- `bin/rails test:system`: Run system tests with Capybara

### Test Stack
- Minitest for unit/integration tests
- Capybara + Selenium for system tests
- Mocha for mocking/stubbing
- WebMock for HTTP request stubbing

### Test Guidelines
- Write tests for all new features and bug fixes
- System tests for user flows and JavaScript interactions
- Controller tests for authentication/authorization
- Model tests for business logic and validations
- Use fixtures for test data (located in test/fixtures/)
- Tests MUST BE DETERMINISTIC - no random data without seeds
- NEVER SKIP TESTS - if tests fail, fix them before proceeding

## Code Quality

### Linting & Security
- `bin/rubocop`: Run Ruby linting (based on rubocop-rails-omakase)
- `bin/brakeman`: Run security analysis
- Both should pass before committing

### Style Guidelines

#### Ruby
- Follow Rails conventions and rubocop-rails-omakase style
- Snake_case for methods and variables
- CamelCase for classes and modules
- Use Rails helpers and concerns for shared functionality
- Prefer instance variables in controllers, locals in views
- Use strong parameters in controllers
- Keep controllers thin, move logic to models/services

#### JavaScript (Stimulus)
- Controllers live in `app/javascript/controllers/`
- Follow Stimulus conventions: targets, values, actions
- Use data attributes for controller connections
- Keep controllers focused and single-purpose
- Prefer Turbo Streams for dynamic updates over custom JS

#### Views
- Use partials for reusable components
- Prefer Turbo Frames for isolated updates
- Use helpers for complex view logic
- Keep views semantic and accessible

## Database

### Migrations
- `bin/rails db:migrate`: Run pending migrations
- `bin/rails db:rollback`: Rollback last migration
- `bin/rails db:reset`: Drop, create, migrate, and seed database
- Always include both `up` and `down` methods (or use `change`)
- Test migrations in both directions

### Console
- `bin/rails console`: Open Rails console for database queries and debugging
- Use for investigating data, testing queries, debugging issues
- Be careful with data modifications in development

## Key Features to Understand

### Rooms
- Central entity: public rooms (visible to all) vs closed rooms (invitation only)
- Direct messages are a special type of room between two users
- Room permissions controlled via `rooms_users` join table

### Real-time Features
- Action Cable channels in `app/channels/`
- `RoomChannel`: broadcasts new messages
- `PresenceChannel`: tracks online users
- `TypingNotificationsChannel`: shows typing indicators
- `UnreadRoomsChannel`: syncs unread counts

### Messages
- Support text, attachments, @mentions, boosts (likes)
- Rich text via Action Text
- Attachments handled via Active Storage
- Unfurling for links (previews)

### Authentication
- Custom bcrypt-based authentication (no Devise)
- Session-based auth via `Authentication` concern
- Authorization via `Authorization` concern
- Bot authentication via API keys

### Bot Integration
- API endpoints for bots to send messages
- Bot users with special permissions
- API key authentication

## Common Patterns

### Controllers
- Include `Authentication` concern for user authentication
- Include `Authorization` concern for permission checks
- Use `RoomScoped` concern for room-specific controllers
- Set current request attributes with `SetCurrentRequest`

### Models
- Use `Current` attributes for thread-safe global state
- Leverage Active Record callbacks sparingly
- Use validations extensively
- Prefer associations over manual queries

### Background Jobs
- Jobs inherit from `ApplicationJob`
- Use for: sending notifications, processing files, async operations
- Keep jobs idempotent and retryable

## Docker Deployment
- `docker build -t campfire .`: Build production image
- Image includes: web server, background workers, SSL (via thruster)
- Persist data by mounting volume to `/rails/storage`
- Configure via environment variables (see README)

## Error Handling
- Use Sentry for production error tracking (if SENTRY_DSN configured)
- Handle errors gracefully in controllers with rescue blocks
- Log important events for debugging

## Security Considerations
- CSRF protection enabled by default
- Use strong parameters in all controllers
- Sanitize user input in views (handled by Rails helpers)
- Run Brakeman before major changes
- Keep dependencies updated
- Validate file uploads (type, size)

## Performance
- Use fragment caching for expensive view renders
- Leverage Russian Doll caching for nested partials
- Use counter caches for associations with counts
- Optimize N+1 queries with `includes`/`eager_load`
- Redis caching for frequently accessed data

## Development Tips
- Check `app/models/current.rb` for available global state
- Use `rails routes` to see all available endpoints
- Turbo Streams in `app/views/**/*.turbo_stream.erb` for live updates
- Stimulus controllers auto-register via `app/javascript/controllers/index.js`
- Check `config/routes.rb` for routing structure
- First-run experience handled by `FirstRunsController`

## Common Tasks

### Adding a new feature
1. Write failing tests first (TDD)
2. Implement feature in appropriate layer (model/controller/view)
3. Add Stimulus controller if JavaScript needed
4. Update routes if new endpoints needed
5. Run tests and ensure they pass
6. Run rubocop and fix style issues
7. Test in browser manually

### Debugging
1. Use `rails console` to inspect database state
2. Check logs in `log/development.log`
3. Use `debug` gem (breakpoint with `debugger`)
4. Inspect Action Cable connections in browser console
5. Use Rails logger in code: `Rails.logger.debug "message"`

### Adding dependencies
- Ruby gems: Add to Gemfile, run `bundle install`
- JavaScript: Use importmap - `bin/importmap pin package-name`
