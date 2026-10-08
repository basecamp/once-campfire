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

## Running your own Campfire instance

Campfire's Docker image contains everything needed for a fully-functional,
single-machine deployment. This includes the web app, background jobs, caching,
file serving, and SSL. You can use our pre-built image at
`ghcr.io/basecamp/once-campfire:latest`, or build your own from this repo.

### Deploying with ONCE

The easiest way to self-host Campfire is with [ONCE](https://github.com/basecamp/once).
It will guide you through the initial set up and then keep your instance up to date automatically.

If you don't already have `once` installed, run this on the machine you want to run Campfire on:

```sh
curl https://get.once.com | sh
```

`once` will launch as soon as the install is finished. 

Choose Campfire from the list of applications, follow the instructions, and ONCE will take care of the rest.

If you prefer the command line to the dashboard, you can deploy directly:

```sh
once deploy ghcr.io/basecamp/once-campfire --host chat.example.com
```

### Deploying with Docker

If you'd rather run the Docker image yourself, you can read more about that in the [self-hosting guide](docs/self-hosting.md).

> [!TIP]
> When you start Campfire for the first time, you'll be guided through a wizard to create an admin account.
> The email address that you enter for the admin account will be visible on the sign-in page, it's there so
> that people have someone to contact if they need help with their account. If that bothers you, put in any
> email address you want and create yourself a new admin account.

Authenticated room, message, sidebar and search pages use a bounded 64 MiB cache per worker.
Set `CAMPFIRE_RESPONSE_CACHE_MB=0` to disable it. Every request still checks authentication
and room access; commits from any SQLite writer invalidate pages, and CSRF masks stay fresh.
Native HTML, JSON and stream fragments have a separate 64 MiB memory limit per worker;
shared rate limits retain their existing store.

## Other implementations

Campfire also has implementations in Django, Laravel, Express, Elixir, Go, Rust and C:

| HTTP workload (requests/sec) | Rails | [Django](https://github.com/basecamp/once-campfire-django) | [Laravel](https://github.com/basecamp/once-campfire-laravel) | [Express](https://github.com/basecamp/once-campfire-express) | [Elixir](https://github.com/basecamp/once-campfire-elixir) | [Go](https://github.com/basecamp/once-campfire-go) | [Rust](https://github.com/basecamp/once-campfire-rust) | [C](https://github.com/basecamp/once-campfire-c) |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Room page | 710 | 414 | 1,696 | 42,481 | 1,126 | 52,512 | 105,909 | 137,505 |
| Messages page | 1,113 | 454 | 1,890 | 74,779 | 1,407 | 54,100 | 103,301 | 142,669 |
| Sidebar | 1,901 | 576 | 3,364 | 94,460 | 3,621 | 58,714 | 120,930 | 151,001 |
| Search | 1,332 | 549 | 2,615 | 83,493 | 2,127 | 60,444 | 121,502 | 148,766 |
| Post a message | 226 | 113 | 567 | 2,121 | 1,392 | 9,000 | 8,004 | 7,486 |

[Shared verification](https://github.com/basecamp/once-campfire-verification) · [Detailed results](https://github.com/basecamp/once-campfire-verification/blob/main/docs/performance-review.md).

Measured with 16 concurrent clients on an AMD Ryzen AI MAX+ 395 with 32 GB RAM,
with four hardware cores allocated to each app.

## Development

You are welcome - and encouraged - to modify Campfire to your liking.
Please see our [development guide](docs/development.md) for how to get Campfire set up for local development.

## Security

See [SECURITY.md](SECURITY.md) for how to report a vulnerability and a description of our trust model.

## Request protection

Browser writes use Rails' `Sec-Fetch-Site` header-only forgery protection and its
`Origin` check. HTTPS requires modern browser metadata; plain HTTP retains the
missing-header fallback with the existing `SameSite=Lax` cookies. Authenticated
bot APIs and signed disk-upload capabilities keep their existing exemptions.
Forms contain no CSRF tokens. Authenticated page caches reuse complete HTML and
gzip bodies while checking current sessions, permissions and SQLite changes.
Existing installation cookies remain valid, including old token-bearing cookies.
