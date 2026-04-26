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

To configure additional features, you can set the following environment variables:

- `SSL_DOMAIN` - enable automatic SSL via Let's Encrypt for the given domain name
- `DISABLE_SSL` - alternatively, set `DISABLE_SSL` to serve over plain HTTP
- `VAPID_PUBLIC_KEY`/`VAPID_PRIVATE_KEY` - set these to a valid keypair to
  allow sending Web Push notifications. You can generate a new keypair by running
  `/script/admin/create-vapid-key`
- `SENTRY_DSN` - to enable error reporting to sentry in production, supply your
  DSN here

### Single Sign-On (SSO)

Campfire supports SSO via OpenID Connect (OIDC), allowing integration with
identity providers such as Keycloak, Okta, Azure AD, and Google Workspace.
SSO is entirely optional — when no SSO environment variables are set, the login
page shows only the standard email/password form.

Both SSO and password authentication can coexist. Users who first registered with
a password will have their account automatically linked when they sign in via SSO
(matched by email address). New users signing in via SSO for the first time are
created automatically and do not need a join code.

To disable password-based registration (so new users can only join via SSO), set:

- `DISABLE_PASSWORD_REGISTRATION=true` - disables the join code registration
  page and hides the invite link from the admin panel. Existing users can still
  sign in with their password.

**OIDC configuration (multiple providers):**

- `OIDC_PROVIDERS` - comma-separated provider keys (for example: `google,github,keycloak`)
- For each key, define:
  - `OIDC_<KEY>_ISSUER` - issuer URL
  - `OIDC_<KEY>_CLIENT_ID` - client ID
  - `OIDC_<KEY>_CLIENT_SECRET` - client secret
  - `OIDC_<KEY>_REDIRECT_URI` - callback URL (for example `https://chat.example.com/auth/oidc_google/callback`)
- Optional per provider:
  - `OIDC_<KEY>_PROVIDER_NAME` - label shown on the sign-in button (defaults to titleized key)
  - `OIDC_<KEY>_SCOPE` - scopes separated by spaces or commas (defaults to `openid email profile`)
  - `OIDC_<KEY>_CLIENT_AUTH_METHOD` - client auth method (defaults to `basic`)
  - `OIDC_<KEY>_END_SESSION_ENDPOINT` - explicit RP-initiated logout endpoint (otherwise discovered from issuer metadata - `${OIDC_<KEY>_ISSUER}/.well-known/openid-configuration`)

Provider keys must use lowercase letters, numbers, and underscores.
When a user signs out from Campfire, the app also attempts OIDC RP-initiated
logout with the provider used for that login session and includes
`id_token_hint` when available.

For example:

    docker build -t campfire .

    docker run \
      --publish 80:80 --publish 443:443 \
      --restart unless-stopped \
      --volume campfire:/rails/storage \
      --env SECRET_KEY_BASE=$YOUR_SECRET_KEY_BASE \
      --env VAPID_PUBLIC_KEY=$YOUR_PUBLIC_KEY \
      --env VAPID_PRIVATE_KEY=$YOUR_PRIVATE_KEY \
      --env TLS_DOMAIN=chat.example.com \
      campfire

With OIDC SSO enabled:

    docker run \
      --publish 80:80 --publish 443:443 \
      --restart unless-stopped \
      --volume campfire:/rails/storage \
      --env SECRET_KEY_BASE=$YOUR_SECRET_KEY_BASE \
      --env TLS_DOMAIN=chat.example.com \
      --env OIDC_PROVIDERS=google,keycloak \
      --env OIDC_GOOGLE_ISSUER=https://accounts.google.com \
      --env OIDC_GOOGLE_CLIENT_ID=$YOUR_GOOGLE_CLIENT_ID \
      --env OIDC_GOOGLE_CLIENT_SECRET=$YOUR_GOOGLE_CLIENT_SECRET \
      --env OIDC_GOOGLE_REDIRECT_URI=https://chat.example.com/auth/oidc_google/callback \
      --env OIDC_GOOGLE_PROVIDER_NAME=Google \
      --env OIDC_KEYCLOAK_ISSUER=https://keycloak.example.com/realms/campfire \
      --env OIDC_KEYCLOAK_CLIENT_ID=campfire \
      --env OIDC_KEYCLOAK_CLIENT_SECRET=$YOUR_KEYCLOAK_CLIENT_SECRET \
      --env OIDC_KEYCLOAK_REDIRECT_URI=https://chat.example.com/auth/oidc_keycloak/callback \
      --env OIDC_KEYCLOAK_PROVIDER_NAME=Keycloak \
      campfire

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
