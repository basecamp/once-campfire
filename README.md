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

## Other implementations

Campfire also has implementations in Elixir, Go and Rust:

| HTTP workload (requests/sec) | Ruby (Rails) | [Elixir](https://github.com/basecamp/once-campfire-elixir) | [Go](https://github.com/basecamp/once-campfire-go) | [Rust](https://github.com/basecamp/once-campfire-rust) |
|---|---:|---:|---:|---:|
| Room page | 216 | 722 | 3,860 | 36,260 |
| Messages page | 384 | 1,053 | 5,573 | 40,872 |
| Sidebar | 503 | 1,275 | 19,753 | 34,672 |
| Search | 380 | 1,156 | 7,053 | 33,299 |
| Post a message | 267 | 801 | 4,767 | 6,896 |

Medians of two runs per implementation on October 4, 2026: production images, gzip,
identical seed data, 16 concurrent clients and four pinned hardware threads per app on an
AMD Ryzen AI MAX+ 395. Versions were measured in separate sessions; Ruby was measured
before the recent rendering optimizations. Results apply to these implementations on this
machine. See the [full report](https://github.com/basecamp/once-campfire-elixir/blob/main/bench/results/ruby-elixir-go-rust-20261004/report.md)
for revisions, ranges, memory and WebSocket benchmarks.

## Development

You are welcome - and encouraged - to modify Campfire to your liking.
Please see our [development guide](docs/development.md) for how to get Campfire set up for local development.

## Security

See [SECURITY.md](SECURITY.md) for how to report a vulnerability and a description of our trust model.
