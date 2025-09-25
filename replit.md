# Overview

Campfire is a modern web-based chat application built with Ruby on Rails. It provides real-time messaging capabilities with features like multiple rooms, direct messages, file attachments, search functionality, notifications via Web Push, @mentions, and API support for bot integrations. The application is designed as a single-tenant system where public rooms are accessible to all users within the instance.

# User Preferences

Preferred communication style: Simple, everyday language.

# System Architecture

## Frontend Architecture
- **Framework**: Ruby on Rails with Hotwire (Turbo + Stimulus) for modern SPA-like interactions
- **JavaScript**: Modular Stimulus controllers for component behavior, with ES6 modules and import maps
- **Styling**: Custom CSS using CSS custom properties for theming, modern CSS reset, and component-based organization
- **Real-time**: Action Cable for WebSocket connections enabling live messaging, typing indicators, and presence tracking
- **Rich Text**: Trix editor integration with ActionText for message composition and formatting
- **File Handling**: Active Storage for file attachments with preview generation and lightbox display

## Backend Architecture
- **Core Framework**: Ruby on Rails following MVC patterns with domain-driven design
- **Domain Models**: Centered around Room and Message entities with rich associations and callbacks
- **Background Processing**: Active Job for asynchronous tasks like message broadcasting and push notifications
- **Service Objects**: Organized under namespaces (e.g., `Room::MessagePusher`) for complex business logic
- **Message Flow**: After-create triggers handle message broadcasting through dedicated service objects and jobs
- **API Design**: RESTful controllers with support for bot integrations and external API access

## Data Architecture
- **Database**: SQLite for development, designed to support any Rails-compatible database
- **Associations**: Rich text content via ActionText, file attachments via Active Storage
- **Messaging**: Message threading and mentioning system with involvement tracking
- **Notifications**: Default "mentions-only" involvement to reduce noise

## Authentication & Authorization
- **Session Management**: Rails session-based authentication with encrypted cookies
- **Room Access**: Public rooms accessible to all users, private rooms with membership controls
- **Security**: CSRF protection, secure headers, and encrypted session storage

## Real-time Features
- **WebSocket Channels**: Dedicated channels for room messages, presence, typing notifications, and unread status
- **Push Notifications**: Web Push API integration with VAPID key support for browser notifications
- **Presence Tracking**: Real-time user presence with automatic cleanup and refresh mechanisms

## Performance Optimizations
- **Message Pagination**: Client-side paginator with scroll management and content trimming
- **Scroll Management**: Intelligent autoscroll behavior with position maintenance during updates
- **Asset Pipeline**: Modern asset pipeline with importmaps and optimized CSS/JS delivery
- **Caching**: Built-in Rails caching mechanisms for performance optimization

# External Dependencies

## Core Dependencies
- **Ruby on Rails**: Full-stack web framework providing MVC architecture, Active Record ORM, and Action Cable
- **Hotwire (Turbo + Stimulus)**: Modern JavaScript framework for SPA-like interactions without complex build processes
- **Action Cable**: WebSocket integration for real-time features built into Rails
- **Active Storage**: File attachment handling with cloud storage support
- **ActionText with Trix**: Rich text editing and storage capabilities

## JavaScript Libraries
- **Trix Editor**: Rich text editor for message composition with custom extensions for mentions and unfurling
- **Highlight.js**: Syntax highlighting for code blocks in messages with multiple language support
- **Web APIs**: Native browser APIs for notifications, service workers, clipboard, and file sharing

## Development & Testing
- **Performance Testing**: K6 for load testing with WebSocket simulation capabilities
- **Asset Management**: Rails asset pipeline with importmaps for modern JavaScript without bundling

## Production Infrastructure
- **Docker**: Complete containerized deployment with SSL, caching, and background job processing
- **Let's Encrypt**: Automatic SSL certificate provisioning for production deployments
- **Service Workers**: PWA capabilities with offline support and push notification handling

## Optional Integrations
- **Sentry**: Error reporting and monitoring for production environments
- **VAPID Keys**: Web Push notification infrastructure for cross-browser push messaging
- **Import Tools**: Slack export import functionality for migration from existing chat systems (planned feature)

## Storage & Persistence
- **File Storage**: Configurable storage backends via Active Storage (local, S3, etc.)
- **Database**: Flexible database support through Active Record (SQLite default, PostgreSQL production-ready)
- **Session Storage**: Encrypted cookie-based sessions with configurable secret key management