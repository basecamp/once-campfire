# Deploying Campfire with Kamal

This repo ships with a [Kamal 2](https://kamal-deploy.org) configuration so you
can run Campfire as a single-machine production deployment that's roughly
equivalent to the `docker run …` command in the [README](README.md), but with
zero-downtime rollouts, SSL via Let's Encrypt, and one-command rollback.

The image used by Kamal is the same multi-arch container built and pushed to
GitHub Container Registry by `.github/workflows/publish-image.yml`, so you do
not have to build locally.

---

## 1. Prerequisites

- **A target server** with Docker installed and ports 80 and 443 reachable from
  the public internet. Kamal will install kamal-proxy on first run.
- **An SSH key** that lets you `ssh root@SERVER` (or another user with sudo).
- **A domain** whose A record points at the server. SSL provisioning fails
  without DNS, so set this up first.
- **A GHCR pull token** — a GitHub personal access token (classic) with the
  `read:packages` scope. Save it as `KAMAL_REGISTRY_PASSWORD` in your shell.
- **Ruby 3.4.5** locally (see `.ruby-version`) so you can run `bundle exec kamal`.
- **Docker Desktop / Engine** locally (only required if you want to build
  images on your machine; you can skip this and use the GHCR image directly).

## 2. Install the gem

The Gemfile already declares `kamal` in the `:development` group. Install it:

```sh
bundle install
```

That gives you `bundle exec kamal …`. Optional convenience: `bundle binstubs kamal`
to get `bin/kamal`.

## 3. Generate one-time secrets

Generate these once, then keep them somewhere safe (password manager, env vars,
or a CI secret store).

```sh
# Rails secret key base
bin/rails secret

# VAPID keypair for Web Push notifications
./script/admin/create-vapid-key
```

You'll also need:

- `RAILS_MASTER_KEY` — already in `config/master.key` (do not commit it).
- `KAMAL_REGISTRY_PASSWORD` — a GHCR personal access token (see Prerequisites).
- `SENTRY_DSN` — optional, only if you want error reporting.

## 4. Fill in `config/deploy.yml`

Open `config/deploy.yml` and replace the two placeholders:

- `servers.web` → your server's IP or DNS name
- `proxy.host` → the public domain (e.g. `chat.example.com`)

If you forked to a different namespace, also update `image:` and
`registry.username` accordingly.

## 5. Provide secrets

`.kamal/secrets` is committed, but it never holds raw values — only references
to environment variables or a password manager. The simplest path is to export
the variables in your shell before deploying:

```sh
export KAMAL_REGISTRY_PASSWORD=ghp_xxx
export SECRET_KEY_BASE=...
export VAPID_PUBLIC_KEY=...
export VAPID_PRIVATE_KEY=...
# Optional
export SENTRY_DSN=...
```

If you'd rather pull from a password manager, see the commented examples at the
bottom of `.kamal/secrets` (1Password, Bitwarden, AWS Secrets Manager).

## 6. First-time setup

```sh
bundle exec kamal setup
```

This will, on the target server:

1. Install Docker if missing.
2. Boot the `kamal-proxy` container.
3. Pull the Campfire image from GHCR.
4. Create the `campfire_storage` volume and mount it at `/rails/storage`.
5. Start the app, register it with the proxy, and obtain a Let's Encrypt cert.

When it finishes, browse to `https://YOUR-DOMAIN` and Campfire will walk you
through creating the admin account.

## 7. Day-to-day commands

```sh
# Deploy the latest main (builds locally, pushes, rolls out with zero downtime)
bundle exec kamal deploy

# Deploy without rebuilding — pulls the existing image tag from GHCR
bundle exec kamal deploy --skip-push

# Stream logs
bundle exec kamal app logs -f

# Rails console on the server
bundle exec kamal console
# (alias of `kamal app exec --interactive --reuse "bin/rails console"`)

# Shell into the running app container
bundle exec kamal shell

# Roll back to the previous version
bundle exec kamal rollback
```

## SSL options

`config/deploy.yml` defaults to letting **kamal-proxy** terminate SSL and sets
`DISABLE_SSL=true` so Campfire's bundled Thruster speaks plain HTTP behind the
proxy. This is the modern Kamal 2 path and gives you zero-downtime cert
rotations.

If you'd rather use Campfire's built-in Thruster + Let's Encrypt (matches the
plain `docker run` instructions in the README):

1. In `config/deploy.yml`, set `proxy: false`.
2. Remove `DISABLE_SSL` and add `SSL_DOMAIN: your-domain` under `env.clear`.
3. Map host ports: add `servers.web.options.publish: ["80:80", "443:443"]`.

You lose Kamal's zero-downtime cutover with this mode, but the configuration is
simpler and matches what the upstream README documents.

## Sanity check before first deploy

```sh
# Verify the config parses and resolves placeholders
bundle exec kamal config

# Print the audit/permissions check against your server
bundle exec kamal audit
```

Both should exit cleanly. If they don't, fix the reported issue before running
`kamal setup`.
