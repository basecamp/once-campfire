# Repository Guidelines

## Project Structure & Module Organization
- `app/` holds Rails MVC code, views, helpers, jobs, and channels.
- `app/assets/` and `app/javascript/` contain styles, images, and frontend behavior.
- `config/` covers environment config, initializers, routes, storage, and Puma.
- `db/` includes migrations and `db/structure.sql`.
- `test/` contains Minitest suites (unit, controller, system, channels).
- `lib/` holds app-specific extensions and tasks; `script/` includes admin/dev helpers.
This fork adds LiveKit video calls via `app/javascript/controllers/video_call_controller.js`,
`app/views/rooms/show/_video_call.html.erb`, and `app/assets/stylesheets/video_call.css`.

## Build, Test, and Development Commands
- `bin/setup` bootstraps dependencies and prepares the database.
- `bin/rails server` (or `bin/dev`) runs the Rails app locally.
- `bin/rails test` runs the full Minitest suite; add `test/models/...` to scope.
- `bin/rubocop` enforces Ruby style via `rubocop-rails-omakase`.
- `bin/brakeman` and `bin/bundler-audit` run security checks.
- `docker build -t campfire .` and `docker run ...` build/run the image (see `README.md`).
- `docker-compose up` starts the containerized deployment.

## Coding Style & Naming Conventions
- Ruby follows Rails Omakase style (`.rubocop.yml`). Prefer 2-space indentation.
- Ruby files and methods use `snake_case`; classes/modules use `CamelCase`.
- JS files are in `app/javascript/` and follow existing module patterns.
- Views and partials use Rails conventions, e.g. `_form.html.erb` in `app/views/...`.

## Testing Guidelines
- Framework: Minitest with fixtures in `test/fixtures/`.
- Naming: tests live in `test/**/**_test.rb`; system tests in `test/system/`.
- Keep tests focused; prefer adding new coverage alongside touched models/controllers.
For LiveKit changes, add controller tests under `test/controllers/api/livekit/`
and JS-focused system tests in `test/system/`.

## Commit & Pull Request Guidelines
- Commit messages are concise, sentence case, and describe the change (see `git log`).
- Start with a GitHub Discussion for questions/ideas; issues are for actionable work (`CONTRIBUTING.md`).
- PRs should include: clear description, linked issue/discussion, and screenshots for UI changes.
- Call out test coverage and any required follow-up configuration.

## Configuration & Secrets
- Core env vars include `SECRET_KEY_BASE`, `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`, and LiveKit keys.
- SSL toggles: `SSL_DOMAIN` or `DISABLE_SSL`; see `README.md` for deployment examples.
LiveKit requires `LIVEKIT_URL`, `LIVEKIT_API_KEY`, and `LIVEKIT_API_SECRET` (`config/initializers/livekit.rb`).
Tokens are minted by `POST /api/livekit/token`; avatars by `GET /api/livekit/participant_avatar`.
The client loads `livekit-client` from `https://cdn.jsdelivr.net` in `video_call_controller.js`.

## LiveKit Integration Notes
- Room names are derived from Campfire room IDs; participants use user IDs for identity.
- Preserve Stimulus targets and data attributes in `_video_call.html.erb` when changing UI.
- Reference upstream docs as needed: LiveKit overview (`docs.livekit.io`) and the
  LiveKit Meet example (`livekit-examples/meet`) for client UX patterns.
