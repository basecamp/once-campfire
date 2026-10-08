## Self-hosting Campfire

Campfire's Docker image contains everything needed for a fully-functional, single-machine deployment.
This includes the web app, background jobs, caching, file serving, and SSL.

> [!TIP]
> The easiest way to self-host Campfire is with [ONCE](https://github.com/basecamp/once), which handles installation, updates, and backups for you. See the [README](../README.md#deploying-with-once) for details. This guide covers running the Docker image by hand.

We recommend using `ghcr.io/basecamp/once-campfire:latest`, which always points to the most recent tagged release - the most stable and battle-tested version of Campfire.

We provide a tagged release for every major, minor and patch version of Campfire, so you can also pin your deployment to a specific version if you want to avoid unexpected changes. For example:

```bash
# exactly version 1.4.4
ghcr.io/basecamp/once-campfire:1.4.4

# any 1.4.x version
# e.g. 1.4.4 or 1.4.5
# the last number is usually changed for bug fixes
ghcr.io/basecamp/once-campfire:1.4

# any 1.x version
# e.g. 1.4.4 or 1.5.0
# the middle number is usually changed for changes to, or addition of, features
ghcr.io/basecamp/once-campfire:1
```

If you want to live on the bleeding edge, the `main` tag tracks the main release branch instead.
It changes with every merged pull request, so it's the newest - but least battle-tested - version of Campfire.

To run it you'll need three things:
1. a machine that runs Docker
2. a mounted volume (so that your database and file attachments are kept around between restarts)
3. some environment variables for configuration

If you'd rather build the image yourself from your own copy of the source, you can do that too:

```sh
docker build -t campfire .
```

### Mounting a storage volume

Campfire keeps all of its storage - the database and uploaded file attachments - inside the path `/rails/storage`.
By default Docker containers don't persist storage between runs, so you'll want to mount a persistent volume into that location.

The simplest way to do this is with the `--volume` flag with `docker run`. For example:

```sh
docker run --volume campfire:/rails/storage ghcr.io/basecamp/once-campfire:latest
```

That will create a named volume (called `campfire`) and mount it into the correct path.
Docker will manage where that volume is actually stored on your server.

You can also specify the data location yourself, mount a network drive, and more.
Check the Docker documentation to find out more about what's available.

### Configuring with environment variables

To configure your Campfire installation, you can use environment variables.
At a minimum you'll want to configure your secret key and your SSL domain.

#### Secrets

Campfire needs a few secret values that are specific to your instance:

- `SECRET_KEY_BASE` - the basis for cryptographic features like signed cookies. This should be a long, unguessable random string.
- `VAPID_PRIVATE_KEY`/`VAPID_PUBLIC_KEY` - a key pair used for sending Web Push notifications.

You can generate them by running:

```sh
docker run --rm ghcr.io/basecamp/once-campfire:latest script/admin/generate-secrets
```

It prints a fresh set of values ready to set as environment variables:

```
SECRET_KEY_BASE=...
VAPID_PRIVATE_KEY=...
VAPID_PUBLIC_KEY=...
```

Keep them safe and reuse the same values across restarts and upgrades - changing them later will invalidate sessions and push notification subscriptions.

#### SSL

If you want the Campfire container to handle its own SSL (HTTPS) automatically (via Let's Encrypt), you just need to specify the domain name that you're running it on.
You can do that with the `TLS_DOMAIN` environment variable.

> [!NOTE]
> If you're using SSL, you'll want to allow traffic on ports 80 and 443.

So if you were running on `chat.example.com` you could enable SSL like this:

```sh
docker run --publish 80:80 --publish 443:443 --env TLS_DOMAIN=chat.example.com ...
```

If you are terminating SSL in some other proxy in front of Campfire, or aren't using SSL at all (for example, if you want to run it locally on your laptop), then you should set `DISABLE_SSL=true` instead and just publish port 80:

```sh
docker run --publish 80:80 --env DISABLE_SSL=true ...
```

#### Error reporting (optional)

To enable error reporting to Sentry in production, supply your DSN in the `SENTRY_DSN` environment variable.
To disable Sentry initialization entirely, set `SKIP_TELEMETRY=true`.

### Example

Putting it all together, here's a complete `docker run` invocation:

```sh
docker run \
  --name campfire \
  --publish 80:80 --publish 443:443 \
  --restart unless-stopped \
  --volume campfire:/rails/storage \
  --env SECRET_KEY_BASE=$YOUR_SECRET_KEY_BASE \
  --env VAPID_PUBLIC_KEY=$YOUR_PUBLIC_KEY \
  --env VAPID_PRIVATE_KEY=$YOUR_PRIVATE_KEY \
  --env TLS_DOMAIN=chat.example.com \
  ghcr.io/basecamp/once-campfire:latest
```

And here's an equivalent `docker-compose.yml` that you could use to run Campfire via `docker compose up`:

```yaml
services:
  web:
    image: ghcr.io/basecamp/once-campfire:latest
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    environment:
      - SECRET_KEY_BASE=abcdefabcdef
      - TLS_DOMAIN=chat.example.com
      - VAPID_PRIVATE_KEY=myvapidprivatekey
      - VAPID_PUBLIC_KEY=myvapidpublickey
    volumes:
      - campfire:/rails/storage

volumes:
  campfire:
```

### First run

When you start Campfire for the first time, you'll be guided through creating an admin account.

> [!TIP]
> The email address of this admin account will be shown on the login page so that people who forget their password know who to contact for help.
> (You can change this email later in the settings.)

Campfire is single-tenant: any rooms designated "public" will be accessible by all users in the system.
To support entirely distinct groups of customers, you would deploy multiple instances of the application.

### Upgrading

All of Campfire's state lives in the mounted volume, so upgrading is a matter of pulling a newer image and recreating the container:

> [!IMPORTANT]
> Before upgrading from Resque to Solid Queue, follow the [queue migration notes](upgrades/solid-queue.md). The old queue must be drained while the old container is still running.

```sh
docker pull ghcr.io/basecamp/once-campfire:latest
```

Any pending database migrations run automatically when the container boots.

Production Rails cache, background jobs, and Action Cable each use a separate SQLite database: `production_cache.sqlite3`, `production_queue.sqlite3`, and `production_cable.sqlite3`. Startup's normal `db:prepare` creates them from the checked-in schemas. Solid Cache's 256 MiB `max_size` is an estimated eviction target, not a cap on SQLite/WAL disk usage. Cache entries and Action Cable broadcasts are disposable and are not migrated; Solid Cable delivers broadcasts through database polling, so allow for its configured polling interval (100 ms by default). The bounded per-worker response and fragment caches remain in memory and are separate from `Rails.cache`. Redis is no longer required.

See the [Solid Cache](upgrades/solid-cache.md), [Solid Queue](upgrades/solid-queue.md), and [Solid Cable](upgrades/solid-cable.md) upgrade notes for migration and backup/restore behavior.

### Backups

Primary records and Solid Queue jobs live in separate SQLite databases, so separate online snapshots are not one point-in-time backup. Stop every Campfire web and job process before generating snapshots and copying the volume. The normal ONCE pre-backup hook deliberately requests ONCE's pause-before-copy fallback for the same reason; its nonzero hook result is intentional.

For a single Docker container, stop the app, run the snapshot command in a one-off container using its stopped volume, archive the volume, and restart the app:

```sh
docker stop campfire
trap 'docker start campfire' EXIT

docker run --rm --volumes-from campfire \
  ghcr.io/basecamp/once-campfire:latest \
  script/admin/prepare-backup

Then archive the storage volume to a file on the host, excluding the disposable cache and Action Cable databases:

```sh
docker run --rm \
  --user root \
  --volumes-from campfire \
  --volume "$PWD":/backup \
  ghcr.io/basecamp/once-campfire:latest \
  tar czf "/backup/campfire-backup.tar.gz" --exclude='storage/db/production_cache.sqlite3*' --exclude='storage/db/production_cable.sqlite3*' -C /rails storage
```

This gives you a `campfire-backup.tar.gz` in your current directory containing consistent primary and Solid Queue snapshots, plus uploaded files. The disposable Solid Cache and Solid Cable databases are excluded and rebuilt empty after a restore. Copy it somewhere safe, ideally off the machine.

If you're using Docker Compose, stop every service that can write to either database, run `script/admin/prepare-backup` in a one-off web container, archive the shared storage volume, then start the services again. Do not run the snapshot and archive commands against a live web/worker process.

To restore, extract the archive back into a stopped instance's volume and run the restore hook:

```sh
docker run --rm \
  --user root \
  --volume campfire:/rails/storage \
  --volume "$PWD":/backup \
  ghcr.io/basecamp/once-campfire:latest \
  bash -c "tar xzf /backup/campfire-backup.tar.gz -C /rails &&
           /hooks/post-restore &&
           chown -R rails:rails /rails/storage"
```

Then start Campfire again.

Backups made before the Solid Queue migration do not contain a queue database. When restoring one after upgrading, follow the instructions in the [queue migration notes](upgrades/solid-queue.md) to explicitly reset the queue database before running the restore hook. The restore hook also clears disposable cache and cable databases so they cannot contain state newer than the restored primary database.
