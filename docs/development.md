## Development

### Setting up

First, get everything installed and configured with:

```sh
bin/setup
```

This installs the system packages Campfire needs (SQLite, ffmpeg), the right Ruby version (via [mise](https://mise.jdx.dev)), and the app's gems; prepares the database; and starts Redis (in a Docker container called `campfire-redis`, if it isn't already running locally).

If you want to start over at any point, run:

```sh
bin/setup --reset
```

### Running the server

Start the development server with:

```sh
bin/dev
```

You'll be able to access the app at http://localhost:3000.

On first run you'll be guided through creating your admin account, and you can sign in with that account from then on.

Note that Campfire needs Redis (for Action Cable, caching, and background jobs), so if you've restarted your machine or stopped the container, `docker start campfire-redis` will bring it back.

### Web Push notifications

Campfire uses VAPID (Voluntary Application Server Identification) keys to send browser push notifications. For notifications to work in development you'll need to generate a key pair and set these environment variables:

- `VAPID_PRIVATE_KEY`
- `VAPID_PUBLIC_KEY`

You can generate a fresh pair (along with a secret key base, which you can ignore in development) by running:

```sh
script/admin/generate-secrets
```

### Running tests

Run the unit tests with:

```sh
bin/rails test
```

And the browser-based system tests with:

```sh
bin/rails test:system
```

Before pushing your changes, you can run the full CI suite locally - style checks, security audits, and all the tests - with a single command:

```sh
bin/ci
```

### Contributing

You are welcome - and encouraged - to modify Campfire to your liking.
If you'd like to contribute your changes back, please read our [contributing guide](../CONTRIBUTING.md) first.
