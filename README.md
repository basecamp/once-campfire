# Campfire

Campfire is a web-based chat application. It supports many of the features you'd
expect, including:

- Multiple rooms, with access controls
- Direct messages
- File attachments with previews
- Search
- Notifications (via Web Push)
- @mentions
- API, with support for bot integrations

## Deploying with Docker

Campfire's Docker image contains everything needed for a fully-functional,
single-machine deployment. This includes the web app, background jobs, caching,
file serving, and SSL.

To persist storage of the database and file attachments, map a volume to `/rails/storage`.

`SECRET_KEY_BASE` is generated automatically at container startup if it is not
provided, so no environment variables are required to get started.

To configure additional features, you can set the following environment variables:

- `SECRET_KEY_BASE` - secret used to sign sessions; auto-generated at startup if omitted
- `SSL_DOMAIN` - enable automatic SSL via Let's Encrypt for the given domain name
- `DISABLE_SSL` - alternatively, set `DISABLE_SSL` to serve over plain HTTP
- `VAPID_PUBLIC_KEY`/`VAPID_PRIVATE_KEY` - set these to a valid keypair to
  allow sending Web Push notifications. You can generate a new keypair by running
  `/script/admin/create-vapid-key`
- `SENTRY_DSN` - to enable error reporting to sentry in production, supply your
  DSN here

### Quickstart with Docker Compose (recommended, works on Windows)

The included `docker-compose.yml` is the easiest way to run Campfire locally,
including on Windows with Docker Desktop:

    docker compose up --build

This builds the image, starts the container on ports 80/443, and persists data
in a named Docker volume (`campfire_storage`). No environment variables are
needed — a `SECRET_KEY_BASE` is generated automatically.

Edit `docker-compose.yml` to uncomment `SSL_DOMAIN`, `VAPID_PUBLIC_KEY`, or
other options when you are ready to configure them.

### Manual docker run

    docker build -t campfire .

    docker run \
      --publish 80:80 --publish 443:443 \
      --restart unless-stopped \
      --volume campfire:/rails/storage \
      --env DISABLE_SSL=true \
      campfire

Pass `--env VAPID_PUBLIC_KEY=...` and `--env VAPID_PRIVATE_KEY=...` to enable
Web Push notifications, and `--env SSL_DOMAIN=chat.example.com` instead of
`DISABLE_SSL` for automatic HTTPS via Let's Encrypt.

> **Windows note:** if you build the image on Windows, make sure your Git client
> is configured to check out files with LF line endings (`git config
> core.autocrlf false`), or the shell scripts inside the container will fail
> with "bad interpreter" errors. The repository's `.gitattributes` file enforces
> LF for all `bin/` scripts, so this is handled automatically as long as your
> Git version respects `.gitattributes`.

## Running in development

    bin/setup
    bin/rails server

## Worth Noting

When you start Campfire for the first time, you’ll be guided through
creating an admin account.
The email address of this admin account will be shown on the login page
so that people who forget their password know who to contact for help.
(You can change this email later in the settings)

Campfire is single-tenant: any rooms designated "public" will be accessible by
all users in the system. To support entirely distinct groups of customers, you
would deploy multiple instances of the application.
