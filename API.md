# Campfire Bot API Documentation

This document provides comprehensive documentation for integrating bots with Campfire using the Bot API and Webhooks.

## Table of Contents

1. [Overview](#overview)
2. [Authentication](#authentication)
3. [Bot API Endpoints](#bot-api-endpoints)
4. [Webhook Integration](#webhook-integration)
5. [Best Practices](#best-practices)
6. [Examples](#examples)
7. [Troubleshooting](#troubleshooting)

## Overview

Campfire supports bot integrations through two complementary mechanisms:

1. **Bot API**: Allows bots to post messages to rooms
2. **Webhooks**: Notifies bots when they're mentioned or when messages appear in DM rooms

### Use Cases

- **CI/CD Notifications**: Deployment status, build results, test reports
- **Monitoring Alerts**: Server issues, performance metrics, uptime alerts
- **Task Management**: Issue tracking updates, PR notifications
- **Custom Workflows**: Approval requests, scheduled reminders, polls
- **Interactive Bots**: Command processing, data lookups, automated responses

### Prerequisites

To integrate a bot, you need:
1. Admin access to Campfire instance
2. A bot user created via the admin panel
3. The bot's API key (format: `{bot_id}-{bot_token}`)

## Authentication

### Bot API Key

Bot authentication uses a composite key format:

```
{bot_id}-{bot_token}
```

**Example**: `7-kR3x9mP8qL2nZ5vT6wY1uE4sA0`

### Creating a Bot User

**Via Admin Panel**:
1. Navigate to Settings → Bots
2. Click "New Bot"
3. Enter bot name and email
4. Save and copy the API key (shown once)

**Via Rails Console** (for self-hosted deployments):
```ruby
bot = User.create!(
  name: "Deploy Bot",
  email_address: "deploy-bot@example.com",
  role: :bot
)

bot.regenerate_bot_token
puts "Bot API Key: #{bot.bot_key}"
# => Bot API Key: 7-kR3x9mP8qL2nZ5vT6wY1uE4sA0
```

### Security Considerations

- **HTTPS Required**: Always use HTTPS to protect API keys in transit
- **Key Storage**: Store API keys securely (environment variables, secret managers)
- **Key Rotation**: Regenerate keys periodically or if compromised
- **Access Scope**: Bots can only access rooms they're members of
- **Rate Limiting**: Not currently enforced, but respect system resources

## Bot API Endpoints

### POST /rooms/:room_id/:bot_key/messages

Post a message to a room as a bot.

#### Request

**URL Structure**:
```
POST https://{campfire-domain}/rooms/{room_id}/{bot_key}/messages
```

**Headers**:
```
Content-Type: application/json
```

**Body Parameters**:

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `body` | string | Yes | Message content (plain text or HTML) |
| `client_message_id` | string | Recommended | Unique ID for idempotency |
| `subject` | string | No | Message subject/title |

**Example Request**:
```bash
curl -X POST https://chat.example.com/rooms/42/7-kR3x9mP8qL2nZ5vT6wY1uE4sA0/messages \
  -H "Content-Type: application/json" \
  -d '{
    "body": "Deploy to production completed successfully! 🚀",
    "client_message_id": "deploy-2024-01-15-12345"
  }'
```

#### Response

**Success (201 Created)**:
```json
{
  "id": 98765,
  "room_id": 42,
  "creator_id": 7,
  "body": "Deploy to production completed successfully! 🚀",
  "created_at": "2024-01-15T10:30:00Z"
}
```

**Error Responses**:

**403 Forbidden** (invalid bot key or not room member):
```json
{
  "error": "Forbidden"
}
```

**404 Not Found** (room doesn't exist):
```json
{
  "error": "Room not found"
}
```

**422 Unprocessable Entity** (validation error):
```json
{
  "error": "Body can't be blank"
}
```

**422 Unprocessable Entity** (duplicate client_message_id):
```json
{
  "error": "Client message has already been taken"
}
```

### Message Formatting

#### Plain Text
```json
{
  "body": "This is a plain text message with @mentions and links: https://example.com"
}
```

#### HTML (Rich Text)
```json
{
  "body": "<div>This is <strong>bold</strong> and <em>italic</em> text.</div>"
}
```

**Supported HTML Tags**:
- Text formatting: `<strong>`, `<em>`, `<u>`, `<strike>`
- Structure: `<div>`, `<p>`, `<br>`, `<blockquote>`
- Lists: `<ul>`, `<ol>`, `<li>`
- Links: `<a href=\"...\">` (auto-sanitized for safety)
- Code: `<code>`, `<pre>`

**Note**: Campfire sanitizes HTML to prevent XSS attacks. Unsafe tags and attributes are stripped.

#### Mentions

To mention a user, you need to use ActionText mention format:
```json
{
  "body": "@username please review the deployment"
}
```

For HTML mentions (ActionText SGIDs):
```html
<action-text-attachment sgid="..." content-type="application/vnd.campfire.mention+json"></action-text-attachment>
```

**Note**: Plain text mentions (e.g., `@username`) are rendered as text, not interactive mentions. For interactive mentions, use the webhook response format (see below).

### Idempotency

Use `client_message_id` to make message posting idempotent:

```bash
# First request - creates message
curl -X POST .../messages -d '{"body": "Hello", "client_message_id": "unique-id-123"}'
# Response: 201 Created, {"id": 100, ...}

# Retry - fails gracefully
curl -X POST .../messages -d '{"body": "Hello", "client_message_id": "unique-id-123"}'
# Response: 422 Unprocessable Entity
```

**Benefits**:
- Safe to retry on network errors
- Prevents duplicate messages
- Ensures exactly-once delivery

**Best Practice**: Generate client_message_id from:
- UUID v4
- Timestamp + random suffix
- Hash of message content + timestamp

**Example**:
```ruby
require 'securerandom'
client_message_id = "bot-#{Time.now.to_i}-#{SecureRandom.hex(8)}"
```

## Webhook Integration

Webhooks allow Campfire to notify your bot when events occur.

### Webhook Setup

**Via Admin Panel**:
1. Settings → Bots → Select bot
2. Navigate to desired room
3. Create webhook with URL: `https://your-bot.com/webhooks/campfire`

**Via Rails Console**:
```ruby
bot = User.find_by(role: :bot, name: "Deploy Bot")
room = Room.find_by(name: "Engineering")

webhook = room.webhooks.create!(
  user: bot,
  url: "https://your-bot.com/webhooks/campfire"
)
```

### Webhook Triggers

Your webhook receives POST requests when:

1. **Bot is @mentioned in a room message**
   ```
   User: "@deploybot deploy to staging"
   → POST to webhook URL
   ```

2. **Any message in a direct message room containing the bot**
   ```
   User creates DM with bot
   User: "What's the deployment status?"
   → POST to webhook URL
   ```

### Webhook Payload

**Request**:
```
POST https://your-bot.com/webhooks/campfire
Content-Type: application/json
```

**Payload Structure**:
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
    "body_html": "<div>@deploybot please deploy <strong>v2.3.1</strong> to staging</div>",
    "body_text": "@deploybot please deploy v2.3.1 to staging",
    "created_at": "2024-01-15T10:30:00Z"
  }
}
```

**Field Descriptions**:

| Field | Type | Description |
|-------|------|-------------|
| `user.id` | integer | User who sent the message |
| `user.name` | string | User's display name |
| `user.email` | string | User's email address |
| `room.id` | integer | Room where message was sent |
| `room.name` | string | Room display name |
| `room.type` | string | Room type: `Rooms::Open`, `Rooms::Closed`, or `Rooms::Direct` |
| `message.id` | integer | Message ID |
| `message.body_html` | string | Message content as HTML |
| `message.body_text` | string | Message content as plain text |
| `message.created_at` | datetime | ISO 8601 timestamp |

### Webhook Response

Your webhook can respond with a message to post in the room.

#### Text Response

**Response**:
```json
{
  "text": "Deployment started! I'll notify you when it's complete."
}
```

**Result**: Bot posts the text as a message in the room.

#### Attachment Response

**Response**:
```json
{
  "text": "Deployment complete! See attached log.",
  "attachment_url": "https://your-bot.com/reports/deploy-log.txt"
}
```

**Result**: Bot posts the text and downloads the attachment to the message.

**Supported Attachment Types**:
- Images: JPEG, PNG, GIF
- Videos: MP4, QuickTime
- Documents: PDF, TXT
- Max size: 100 MB

#### No Response

If you don't want to respond, simply return an empty response or non-200 status:
```json
{}
```

Or:
```
HTTP/1.1 204 No Content
```

### Webhook Timeout

**Timeout**: 7 seconds

Your webhook must respond within 7 seconds or the request will timeout.

**Best Practice**:
- Process webhooks asynchronously
- Respond immediately with acknowledgment
- Perform long-running tasks in background jobs

**Example (Ruby)**:
```ruby
post '/webhooks/campfire' do
  payload = JSON.parse(request.body.read)

  # Queue job asynchronously
  ProcessCampfireWebhookJob.perform_later(payload)

  # Respond immediately
  status 202
  json({ text: "Processing your request..." })
end
```

### Webhook Security

#### IP Whitelisting

Restrict webhook endpoints to requests from your Campfire instance:

```ruby
CAMPFIRE_IPS = ['192.0.2.1', '192.0.2.2']

before do
  halt 403 unless CAMPFIRE_IPS.include?(request.ip)
end
```

#### HMAC Signature (Custom Implementation)

Campfire doesn't currently support HMAC signatures, but you can implement your own:

**1. Share a secret with Campfire**:
```ruby
# In Campfire (custom initializer)
WEBHOOK_SECRET = ENV['WEBHOOK_SECRET']

# Before sending webhook
signature = OpenSSL::HMAC.hexdigest('SHA256', WEBHOOK_SECRET, payload)
headers['X-Campfire-Signature'] = signature
```

**2. Verify signature in your bot**:
```ruby
post '/webhooks/campfire' do
  payload = request.body.read
  signature = request.env['HTTP_X_CAMPFIRE_SIGNATURE']

  expected_signature = OpenSSL::HMAC.hexdigest(
    'SHA256',
    ENV['WEBHOOK_SECRET'],
    payload
  )

  halt 403 unless Rack::Utils.secure_compare(signature, expected_signature)

  # Process webhook
end
```

#### HTTPS Only

Always use HTTPS for webhook URLs:
```
✅ https://your-bot.com/webhooks/campfire
❌ http://your-bot.com/webhooks/campfire
```

## Best Practices

### 1. Use Client Message IDs

Always include `client_message_id` for idempotency:
```ruby
def post_message(room_id, text)
  client_message_id = "bot-#{Time.now.to_i}-#{SecureRandom.hex(8)}"

  http.post(
    "/rooms/#{room_id}/#{bot_key}/messages",
    json: { body: text, client_message_id: client_message_id }
  )
end
```

### 2. Handle Rate Limiting Gracefully

Although not currently enforced, implement exponential backoff:
```ruby
def post_with_retry(url, payload, max_retries: 3)
  retries = 0

  begin
    http.post(url, json: payload)
  rescue HTTP::Error => e
    retries += 1
    if retries <= max_retries
      sleep(2 ** retries)  # 2s, 4s, 8s
      retry
    else
      raise
    end
  end
end
```

### 3. Parse Commands from Messages

Extract commands from `body_text`:
```ruby
def parse_command(message)
  text = message['body_text']

  case text
  when /deploy (\w+) to (\w+)/
    { action: :deploy, version: $1, environment: $2 }
  when /status/
    { action: :status }
  else
    { action: :unknown }
  end
end
```

### 4. Provide User-Friendly Responses

**Good**:
```json
{
  "text": "✅ Deployed v2.3.1 to staging successfully!\nURL: https://staging.example.com\nTime: 3m 24s"
}
```

**Bad**:
```json
{
  "text": "OK"
}
```

### 5. Handle Errors Gracefully

Respond with helpful error messages:
```ruby
def handle_webhook(payload)
  command = parse_command(payload['message'])

  case command[:action]
  when :deploy
    deploy(command[:version], command[:environment])
  when :unknown
    {
      text: "Sorry, I didn't understand that command. Try:\n" \
            "• `@#{bot_name} deploy <version> to <env>`\n" \
            "• `@#{bot_name} status`\n" \
            "• `@#{bot_name} help`"
    }
  end
rescue => e
  {
    text: "⚠️ Error: #{e.message}"
  }
end
```

### 6. Log Webhook Deliveries

Track webhook success/failure:
```ruby
post '/webhooks/campfire' do
  payload = JSON.parse(request.body.read)

  logger.info "Webhook received: #{payload.inspect}"

  response = handle_webhook(payload)

  logger.info "Webhook response: #{response.inspect}"

  json(response)
rescue => e
  logger.error "Webhook error: #{e.message}\n#{e.backtrace.join("\n")}"
  status 500
  json({ text: "Internal error occurred" })
end
```

### 7. Test Webhooks Locally

Use ngrok or similar for local testing:

```bash
# Start ngrok
ngrok http 3000

# Use ngrok URL in Campfire webhook settings
https://abc123.ngrok.io/webhooks/campfire
```

### 8. Implement Health Checks

Add a health check endpoint:
```ruby
get '/health' do
  status 200
  json({ status: 'ok', timestamp: Time.now.iso8601 })
end
```

## Examples

### Example 1: Simple Deployment Bot

**Webhook Handler**:
```ruby
require 'sinatra'
require 'json'

# POST /webhooks/campfire
post '/webhooks/campfire' do
  payload = JSON.parse(request.body.read)
  message_text = payload.dig('message', 'body_text')

  if message_text =~ /deploy (\w+)/
    version = $1

    # Trigger deployment asynchronously
    DeployJob.perform_later(version)

    response = {
      text: "🚀 Starting deployment of #{version}...\nI'll notify you when it's done!"
    }
  else
    response = {
      text: "Usage: @deploybot deploy <version>"
    }
  end

  content_type :json
  response.to_json
end
```

**Background Job**:
```ruby
class DeployJob < ApplicationJob
  def perform(version)
    # Run deployment
    result = system("./scripts/deploy.sh #{version}")

    # Post result to room
    if result
      post_message("✅ Deployment of #{version} completed successfully!")
    else
      post_message("❌ Deployment of #{version} failed. Check logs.")
    end
  end

  private

  def post_message(text)
    HTTP.post(
      "https://chat.example.com/rooms/42/#{ENV['BOT_KEY']}/messages",
      json: {
        body: text,
        client_message_id: "deploy-#{Time.now.to_i}"
      }
    )
  end
end
```

### Example 2: Monitoring Alert Bot

**Scheduled Job (runs every 5 minutes)**:
```ruby
class MonitoringCheckJob < ApplicationJob
  def perform
    metrics = fetch_metrics

    if metrics[:cpu_usage] > 90
      alert(
        "⚠️ High CPU Usage Alert\n" \
        "Server: #{metrics[:server]}\n" \
        "CPU: #{metrics[:cpu_usage]}%\n" \
        "Time: #{Time.now}"
      )
    end

    if metrics[:disk_usage] > 85
      alert(
        "⚠️ Low Disk Space Alert\n" \
        "Server: #{metrics[:server]}\n" \
        "Disk: #{metrics[:disk_usage]}% used\n" \
        "Free: #{metrics[:disk_free]} GB"
      )
    end
  end

  private

  def fetch_metrics
    # Fetch from monitoring system
    {
      server: 'web-prod-01',
      cpu_usage: 92,
      disk_usage: 87,
      disk_free: 15
    }
  end

  def alert(message)
    HTTP.post(
      "https://chat.example.com/rooms/42/#{ENV['BOT_KEY']}/messages",
      json: {
        body: message,
        client_message_id: "alert-#{SecureRandom.uuid}"
      }
    )
  end
end
```

### Example 3: Interactive Status Bot

**Webhook Handler**:
```ruby
post '/webhooks/campfire' do
  payload = JSON.parse(request.body.read)
  message_text = payload.dig('message', 'body_text')

  response = case message_text
  when /status/
    check_status
  when /restart (\w+)/
    restart_service($1)
  when /logs (\w+)/
    fetch_logs($1)
  when /help/
    show_help
  else
    { text: "Unknown command. Try `@statusbot help`" }
  end

  content_type :json
  response.to_json
end

def check_status
  services = [
    { name: 'web', status: 'running', uptime: '5d 3h' },
    { name: 'worker', status: 'running', uptime: '5d 3h' },
    { name: 'redis', status: 'running', uptime: '12d 8h' }
  ]

  text = "**Service Status**\n\n"
  services.each do |svc|
    emoji = svc[:status] == 'running' ? '✅' : '❌'
    text += "#{emoji} #{svc[:name]}: #{svc[:status]} (uptime: #{svc[:uptime]})\n"
  end

  { text: text }
end

def restart_service(service_name)
  # Restart service
  result = system("sudo systemctl restart #{service_name}")

  if result
    { text: "✅ Service #{service_name} restarted successfully" }
  else
    { text: "❌ Failed to restart #{service_name}" }
  end
end

def fetch_logs(service_name)
  # Generate log file
  logs = `journalctl -u #{service_name} -n 100`
  log_file = "/tmp/#{service_name}-#{Time.now.to_i}.log"
  File.write(log_file, logs)

  # Upload to public URL (or use attachment_url)
  log_url = upload_to_s3(log_file)

  {
    text: "📄 Last 100 log lines for #{service_name}",
    attachment_url: log_url
  }
end

def show_help
  {
    text: "**Available Commands**\n\n" \
          "• `@statusbot status` - Check service status\n" \
          "• `@statusbot restart <service>` - Restart a service\n" \
          "• `@statusbot logs <service>` - Fetch recent logs\n" \
          "• `@statusbot help` - Show this help"
  }
end
```

### Example 4: GitHub Integration Bot

**Webhook from GitHub → Bot Server → Campfire**:
```ruby
# Receive webhook from GitHub
post '/webhooks/github' do
  payload = JSON.parse(request.body.read)

  case request.env['HTTP_X_GITHUB_EVENT']
  when 'push'
    handle_push(payload)
  when 'pull_request'
    handle_pr(payload)
  when 'issues'
    handle_issue(payload)
  end

  status 200
end

def handle_push(payload)
  repo = payload['repository']['name']
  branch = payload['ref'].split('/').last
  commits = payload['commits']

  message = "🔔 **Push to #{repo}/#{branch}**\n\n"
  commits.each do |commit|
    short_sha = commit['id'][0..7]
    message += "• #{short_sha}: #{commit['message']}\n"
  end
  message += "\nAuthor: #{commits.first['author']['name']}"

  post_to_campfire(message)
end

def handle_pr(payload)
  action = payload['action']
  pr = payload['pull_request']

  emoji = case action
  when 'opened' then '🆕'
  when 'closed' then pr['merged'] ? '✅' : '❌'
  when 'reopened' then '🔄'
  else '📝'
  end

  message = "#{emoji} **Pull Request #{action}**\n\n" \
            "**#{pr['title']}** (##{pr['number']})\n" \
            "By: #{pr['user']['login']}\n" \
            "URL: #{pr['html_url']}"

  post_to_campfire(message)
end

def post_to_campfire(text)
  HTTP.post(
    "https://chat.example.com/rooms/42/#{ENV['BOT_KEY']}/messages",
    json: {
      body: text,
      client_message_id: "github-#{SecureRandom.uuid}"
    }
  )
end
```

## Troubleshooting

### Common Issues

#### 1. 403 Forbidden

**Problem**: Bot API returns 403 Forbidden.

**Causes**:
- Invalid bot key
- Bot is not a member of the room
- Bot user deactivated

**Solution**:
```ruby
# Verify bot key
bot = User.authenticate_bot("7-kR3x9mP8qL2nZ5vT6wY1uE4sA0")
puts bot ? "Valid" : "Invalid"

# Check room membership
room = Room.find(42)
puts room.users.include?(bot) ? "Member" : "Not a member"

# Add bot to room
room.grant_to(bot)
```

#### 2. Duplicate Message Error

**Problem**: 422 error: "Client message has already been taken"

**Cause**: Reusing same `client_message_id`

**Solution**: Generate unique IDs:
```ruby
client_message_id = "bot-#{Time.now.to_i}-#{SecureRandom.hex(8)}"
```

#### 3. Webhook Not Receiving Requests

**Problem**: Webhook endpoint not called when bot mentioned.

**Causes**:
- Webhook URL incorrect
- Bot not mentioned in message
- Webhook URL not accessible from Campfire server

**Solution**:
```bash
# Test webhook URL from Campfire server
curl -X POST https://your-bot.com/webhooks/campfire \
  -H "Content-Type: application/json" \
  -d '{"test": true}'

# Check webhook configuration
webhook = Webhook.find_by(user: bot, room: room)
puts webhook.url
```

#### 4. Webhook Timeout

**Problem**: Webhook times out after 7 seconds.

**Cause**: Long-running processing in webhook handler

**Solution**: Process asynchronously:
```ruby
post '/webhooks/campfire' do
  payload = JSON.parse(request.body.read)

  # Queue for background processing
  ProcessWebhookJob.perform_later(payload)

  # Respond immediately
  status 202
  json({ text: "Processing..." })
end
```

#### 5. HTML Not Rendering

**Problem**: HTML tags appear as plain text in messages.

**Cause**: Improper escaping or unsupported tags

**Solution**:
```ruby
# Use simple HTML
{ body: "<strong>Bold</strong> and <em>italic</em>" }

# Avoid complex HTML
# ❌ { body: "<script>alert('XSS')</script>" }
```

### Debugging Tips

#### 1. Test Bot API with cURL

```bash
curl -v -X POST https://chat.example.com/rooms/42/7-abc123/messages \
  -H "Content-Type: application/json" \
  -d '{"body": "Test message", "client_message_id": "test-123"}'
```

#### 2. Inspect Webhook Payloads

```ruby
post '/webhooks/campfire' do
  File.write("/tmp/webhook-#{Time.now.to_i}.json", request.body.read)
  status 200
end
```

#### 3. Check Bot Membership

```ruby
# Rails console
bot = User.find_by(role: :bot, name: "Deploy Bot")
bot.rooms.pluck(:id, :name)
# => [[42, "Engineering"], [43, "DevOps"]]
```

#### 4. Monitor Webhook Job Queue

```ruby
# Rails console
require 'resque'

# Check queue size
Resque.info
# => {:pending=>5, :processed=>1234, :failed=>0, ...}

# Inspect failed jobs
Resque::Failure.count
```

#### 5. Enable Verbose Logging

```ruby
# config/environments/production.rb
config.log_level = :debug  # Temporarily enable debug logs
```

Check logs for webhook delivery:
```bash
tail -f log/production.log | grep "Bot::WebhookJob"
```

---

## API Reference Summary

### Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| POST | `/rooms/:room_id/:bot_key/messages` | Post message as bot |

### Webhook Events

| Trigger | Description |
|---------|-------------|
| Mention | Bot @mentioned in message |
| Direct Message | Any message in DM room with bot |

### Response Formats

| Format | Fields | Description |
|--------|--------|-------------|
| Text | `text` | Simple text response |
| Attachment | `text`, `attachment_url` | Text with file attachment |
| Empty | `{}` or 204 | No response |

---

## Support

For issues or questions:
- **GitHub Discussions**: https://github.com/basecamp/once-campfire/discussions
- **Issue Tracker**: https://github.com/basecamp/once-campfire/issues
- **Documentation**: See `ARCHITECTURE.md` for technical details

## License

This API documentation is part of Campfire, released under the [MIT License](MIT-LICENSE).
