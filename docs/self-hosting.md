## Self-hosting Campfire

Campfire's Docker image contains everything needed for a fully-functional, single-machine deployment.
This includes the web app, background jobs, caching, file serving, and SSL.

> [!TIP]
> The easiest way to self-host Campfire is with [ONCE](https://github.com/basecamp/once), which handles installation, updates, and backups for you. See the [README](../README.md#installing-with-once-recommended) for details. This guide covers running the Docker image by hand.

The latest version of the docker image can be found at `ghcr.io/basecamp/once-campfire:main`.
This image changes with every merged pull request - it's the bleeding edge version of Campfire.

Tagged releases are also available, for example `ghcr.io/basecamp/once-campfire:v1.4.4`.
These are the most stable and battle-tested versions of Campfire.

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
docker run --volume campfire:/rails/storage ghcr.io/basecamp/once-campfire:main
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
docker run --rm ghcr.io/basecamp/once-campfire:main script/admin/generate-secrets
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
  ghcr.io/basecamp/once-campfire:main
```

And here's an equivalent `docker-compose.yml` that you could use to run Campfire via `docker compose up`:

```yaml
services:
  web:
    image: ghcr.io/basecamp/once-campfire:main
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

```sh
docker pull ghcr.io/basecamp/once-campfire:main
```

Any pending database migrations run automatically when the container boots.

### Backups

To back up your instance, back up the contents of the `/rails/storage` volume.

Because the SQLite database may be written to at any moment, you shouldn't copy its files directly while Campfire is running.
Instead, first run `script/admin/prepare-backup` inside the running container to produce a consistent snapshot of the database (it's written to `storage/backups/` inside the volume):

```sh
docker exec campfire script/admin/prepare-backup
```

(If you're using Docker Compose, replace `docker exec campfire` with `docker compose exec web`)

Then archive the whole storage volume to a file on the host:

```sh
docker run --rm \
  --user root \
  --volume campfire:/rails/storage \
  --volume "$PWD":/backup \
  ghcr.io/basecamp/once-campfire:main \
  tar czf "/backup/campfire-backup.tar.gz" -C /rails storage
```

This gives you a `campfire-backup.tar.gz` in your current directory containing the database snapshot and all uploaded files.
Copy it somewhere safe, ideally off the machine.

To restore, extract the archive back into a (stopped) instance's volume, and replace the live database with the snapshot:

```sh
docker run --rm \
  --user root \
  --volume campfire:/rails/storage \
  --volume "$PWD":/backup \
  ghcr.io/basecamp/once-campfire:main \
  bash -c "tar xzf /backup/campfire-backup.tar.gz -C /rails &&
           cp /rails/storage/backups/production.sqlite3 /rails/storage/db/production.sqlite3 &&
           rm -f /rails/storage/db/production.sqlite3-wal /rails/storage/db/production.sqlite3-shm &&
           chown -R rails:rails /rails/storage"
```

Then start Campfire again.
