# Backlit integration

Campfire runs as a sibling app to Backlit. Identity is Sign in with Backlit (OIDC). Room membership for projects is pushed from Backlit over an internal provisioning API.

## Environment

Set these on the Campfire host (alongside existing `SECRET_KEY_BASE`, VAPID, `TLS_DOMAIN`):

```bash
OIDC_PROVIDERS=backlit
OIDC_BACKLIT_ISSUER=https://bck.lt
OIDC_BACKLIT_CLIENT_ID=...
OIDC_BACKLIT_CLIENT_SECRET=...
OIDC_BACKLIT_REDIRECT_URI=https://campfire.bck.lt/auth/backlit/callback
OIDC_BACKLIT_PROVIDER_NAME=Backlit
DISABLE_PASSWORD_REGISTRATION=true
BACKLIT_PROVISIONING_TOKEN=...
```

Backlit stores the matching OAuth client secret and provisioning token in Rails credentials.

## Provisioning API

All routes require `Authorization: Bearer $BACKLIT_PROVISIONING_TOKEN`.

- `POST /internal/backlit/users` — upsert user by `sub` (JSON: `sub`, `email`, `name`, `admin`)
- `PATCH /internal/backlit/users/:sub` — same
- `POST /internal/backlit/rooms` — create closed room (`name`, `backlit_project_id`, `backlit_kind`)
- `PATCH /internal/backlit/rooms/:id` — rename
- `POST /internal/backlit/rooms/:id/archive` — set `archived_at`, revoke memberships
- `POST /internal/backlit/rooms/:id/memberships` — grant (`subs: [...]`)
- `DELETE /internal/backlit/rooms/:id/memberships` — revoke (`subs: [...]`)

Archived rooms are hidden from the normal sidebar (`Membership.visible` excludes them).

## Deploy

1. Build and push image from this repo (see `.github/workflows/docker.yml`)
2. On `campfire-1`, stop ONCE auto-updates (`once auto-update off`)
3. Run the new image with the same `campfire-data` volume and secrets
4. Keep `TLS_DOMAIN=campfire.bck.lt`

Do not let `once update` overwrite a custom image.
