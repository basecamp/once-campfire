# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Campfire is a single-tenant team chat web application built with Ruby on Rails. One deployment serves one organization. It uses SQLite for storage, Redis for caching/ActionCable/jobs, and Hotwire (Turbo + Stimulus) for the frontend.

## Development Commands

```bash
bin/setup          # Install dependencies, prepare DB, start Redis
bin/dev            # Start Rails server (development)
bin/boot           # Start all processes (web + redis + workers) via Procfile
```

### Testing (Minitest)

```bash
bin/rails test                          # Run all unit/integration tests
bin/rails test test/models/             # Run all model tests
bin/rails test test/controllers/        # Run all controller tests
bin/rails test test/models/user_test.rb # Run a specific test file
bin/rails test test/models/user_test.rb:42  # Run a specific test by line number
bin/rails test:system                   # Run system tests (Capybara + Selenium)
```

Test helpers: Mocha (mocking), WebMock (HTTP stubbing), fixtures auto-loaded.

### Linting

```bash
bin/rubocop        # Run RuboCop (rubocop-rails-omakase style)
bin/rubocop -a     # Auto-fix offenses
```

### Database

```bash
bin/rails db:prepare   # Create/migrate DB
bin/rails db:reset     # Drop and recreate DB
```

SQLite databases stored in `storage/db/`. Schema version managed in `db/schema.rb`.

## Architecture

### Tech Stack

- Ruby 3.4.5, Rails 8.2, SQLite, Redis
- Propshaft (assets), Importmap (JS), Hotwire (Turbo + Stimulus)
- Action Text + Trix (rich text messages), Active Storage (file uploads)
- Resque + resque-pool (background jobs), Action Cable (WebSocket)

### Key Architectural Patterns

**Single-tenant singleton Account**: The `accounts` table has a `singleton_guard` unique constraint — only one Account record can exist. `Account.any?` gates the first-run flow.

**Room STI (Single Table Inheritance)**: `rooms.type` column differentiates `Rooms::Open`, `Rooms::Closed`, and `Rooms::Direct`. Each subclass lives in `app/models/rooms/`.

**FirstRun as PORO**: `app/models/first_run.rb` is a plain Ruby object (not ActiveRecord) that orchestrates initial setup — creating Account, first Room, and administrator User in a single flow.

**Controller concerns in ApplicationController**: Authentication, authorization, ban checking, platform detection, and room visit tracking are mixed in via `include` from `app/controllers/concerns/`.

**Message body via Action Text**: The `messages` table has no body column. Message content is stored in `action_text_rich_texts` (polymorphic).

**Full-text search**: `message_search_index` is an SQLite FTS5 virtual table with porter tokenizer.

**Memberships as join table**: `memberships` connects users to rooms with `involvement` level (invisible/nothing/mentions/everything) and WebSocket connection tracking (`connections`, `connected_at`).

### Process Architecture (Local)

`bin/boot` runs Procfile: web (Puma via thrust), Redis, Resque workers.

### Documentation

Detailed docs in Japanese are in `docs/`: overview, architecture, setup, database schema, routes, and request flow diagrams (`docs/flows/`).
