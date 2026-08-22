## OpenID Connect single sign-on

Campfire can authenticate people through one OpenID Connect (OIDC) provider. It
uses the authorization code flow with state, nonce, and PKCE. The provider is
configured through environment variables, so client secrets are not stored in
Campfire's database.

This integration provides authentication, optional just-in-time account
creation, OIDC Back-Channel Logout, and a deliberately limited SCIM 2.0
deprovisioning surface. It does not implement SAML or general SCIM
provisioning.

### Provider requirements

The provider must support:

- OIDC discovery from `<issuer>/.well-known/openid-configuration`
- The authorization code flow
- PKCE with the `S256` challenge method
- Signed ID tokens using `RS256`
- Token-endpoint authentication using `client_secret_basic`
- A UserInfo endpoint that returns the same `sub` as the ID token
- The `openid`, `email`, and `profile` scopes

Register this callback URL with the provider:

```
https://chat.example.com/auth/openid_connect/callback
```

The value must exactly match `OIDC_REDIRECT_URI`.

If the provider supports OIDC Back-Channel Logout, also register this RP
Back-Channel Logout URI:

```
https://chat.example.com/auth/openid_connect/backchannel_logout
```

The endpoint accepts form-encoded `POST` requests containing exactly one usable
signed `logout_token`. Protocol extensions may add unrelated form parameters;
Campfire ignores them. Missing, blank, oversized, or duplicate `logout_token`
values are rejected. It does not use the browser session or a provider access
token, and every response carries `Cache-Control: no-store`.

### Configuration

Set `OIDC_MODE` and the four required connection values:

```sh
OIDC_MODE=optional
OIDC_ISSUER=https://identity.example.com
OIDC_CLIENT_ID=campfire
OIDC_CLIENT_SECRET=replace-with-the-provider-secret
OIDC_REDIRECT_URI=https://chat.example.com/auth/openid_connect/callback
TLS_DOMAIN=chat.example.com
```

`OIDC_MODE` accepts these values:

| Value | Behavior |
| --- | --- |
| `disabled` | OIDC is off. This is the default. |
| `optional` | People can use either OIDC or their existing Campfire password. |
| `required` | OIDC is required after explicit activation, except for the configured recovery administrator. Existing local sessions are preserved during preflight and revoked by activation. |

Additional settings are optional:

| Variable | Default | Description |
| --- | --- | --- |
| `OIDC_PROVIDER_NAME` | `Single Sign-On` | Name shown on the sign-in button. |
| `OIDC_SIGNING_ALGORITHM` | `RS256` | Expected ID-token algorithm. The initial supported value is `RS256`. |
| `OIDC_CLIENT_AUTH_METHOD` | `basic` | Token-endpoint client authentication. The initial supported value is `basic`. |
| `OIDC_JIT_PROVISIONING` | `false` | Set to `true` to create a member when no Campfire account has the verified provider email. |
| `OIDC_SESSION_LIFETIME` | `43200` | Maximum federated session lifetime in seconds. Allowed range: 300 seconds to 30 days. |
| `OIDC_BREAK_GLASS_EMAIL` | none | Email of one existing Campfire administrator to bind as recovery during activation. Later changes become candidates only after another successful activation. |
| `OIDC_ALLOWED_HOSTS` | issuer host | Comma- or space-separated additional hosts that Campfire may contact for OIDC. |
| `OIDC_ALLOW_PRIVATE_NETWORK` | `false` | Permit OIDC hosts to resolve to private addresses. Only enable this for a trusted internal provider. |
| `OIDC_TRUSTED_PROXY_CIDRS` | none | Required with `DISABLE_SSL=true`. CIDRs of only the TLS proxies that connect directly to Campfire. |
| `HTTPS_PORT` | `443` | Public HTTPS port. It must exactly match the port in `OIDC_REDIRECT_URI`. Built-in Thruster TLS requires `443`; non-default ports are supported only behind an external TLS proxy. |

Campfire fails to boot when its static OIDC configuration is missing or
invalid. `TLS_DOMAIN` is required and must include the host in
`OIDC_REDIRECT_URI`; this canonical host prevents state cookies from being
split across aliases. Provider discovery and connectivity are checked when an
authentication flow starts. Discovery must advertise the code flow, PKCE
`S256`, `RS256`, and `client_secret_basic`. Authentication fails closed if the
provider is unavailable; `required` mode never silently falls back to
passwords.

In built-in TLS mode, Thruster-prefixed `THRUSTER_TLS_DOMAIN`,
`THRUSTER_HTTPS_PORT`, and `THRUSTER_FORWARD_HEADERS` values take precedence.
Campfire validates and fingerprints those effective settings, refuses an empty
or incompatible TLS domain or port, and rejects every Thruster spelling that
enables forwarding. Built-in OIDC TLS is deliberately limited to public port
443 so Thruster's HTTP upgrade always targets the canonical HTTPS port.

OIDC requires browser access over HTTPS even when a reverse proxy terminates
TLS. With `DISABLE_SSL=true`, the proxy must set the forwarded HTTPS scheme;
`OIDC_TRUSTED_PROXY_CIDRS` must identify that proxy's direct source addresses,
and Campfire bypasses its built-in Thruster TLS terminator and listens on port
80. That application port must not be client-accessible. Forwarded HTTPS from an
untrusted address is rejected. Otherwise Campfire redirects safe requests to
its HTTPS canonical origin and rejects unsafe requests. OIDC and authentication
cookies are always marked `Secure` in production.

When Thruster terminates TLS itself, Puma listens only on loopback and accepts
one sanitized client address from that fixed internal hop. Campfire does not
trust arbitrary forwarding headers or operator-supplied proxy CIDRs in this
mode. The pinned Thruster release rejects arbitrary HTTP Host values before
redirecting to an allowed TLS domain.

`/up` remains a process-liveness check. `/up/oidc` separately reports whether
the configured authentication policy is ready, allowing operators to alert on
an unsafe required-mode transition or missing logout-token storage without
creating a restart loop. `/up/scim` reports `disabled`, `ready`, or
`not_ready` independently.

### Outbound host restrictions

Campfire only accepts HTTPS authorization, discovery, token, UserInfo, and JWKS
endpoints. Every endpoint must use the issuer host or a host listed in
`OIDC_ALLOWED_HOSTS`. Public providers that publish endpoints on other hosts
need those hosts listed explicitly.

For example, a Google provider currently needs:

```sh
OIDC_ALLOWED_HOSTS=accounts.google.com,oauth2.googleapis.com,openidconnect.googleapis.com,www.googleapis.com
```

Server-side OIDC requests resolve each hostname once, reject the request if any
returned address is private or special-use, and connect to the validated
address while retaining hostname verification for TLS. Responses are limited
to 1 MB and DNS plus HTTP share one 15-second deadline per provider request.
OIDC initiation is rate- and concurrency-limited before provider work begins.
Back-channel logout is separately body-, rate-, and concurrency-limited before
discovery or signature verification. Discovery and JWKS documents are cached
for at most five minutes. A key ID absent from cached JWKS, or a signature
failure against a cached matching key, permits one rate-controlled refresh so
normal and same-`kid` signing-key rotation are observed without allowing
attacker-controlled tokens to trigger unbounded provider requests.
The initial implementation requires direct egress and does not use an outbound
HTTP proxy. For an internal Keycloak or
similar provider, set `OIDC_ALLOW_PRIVATE_NETWORK=true`; HTTPS and the exact
hostname allowlist are still enforced.

### Account linking and creation

Campfire identifies a returning person using the immutable OIDC `(issuer, sub)`
pair. Existing password accounts are never linked solely because an OIDC login
uses the same email. The account owner must first sign in locally, open their
profile, select **Connect Single Sign-On**, and complete the provider flow in
the same browser. The verified provider email must match the local account.

This explicit step prevents someone from pre-creating an account with another
person's email and later sharing access to it. The provider must assert
`email_verified: true`; a missing or string-valued claim is not accepted.

Once linked, an account is never silently relinked to a different subject from
the same issuer. This protects against email reuse at the identity provider.

When `OIDC_JIT_PROVISIONING=true`, a verified email that does not match an
existing account creates a normal Campfire member. A matching but unlinked
password account is rejected instead of being claimed. JIT never creates an
administrator and cannot run before Campfire's first-run setup. Leave JIT
disabled when provider access does not itself imply authorization to join the
Campfire instance.

### Safe rollout

1. Before starting the new image, use its one-off backup tools to create, authenticate, archive, restore, and test a pre-migration recovery volume as described in the self-hosting guide. Keep the backup HMAC key outside both the source volume and archive storage.
2. Keep `OIDC_MODE=disabled` while registering the OIDC client. A fresh installation cannot bootstrap directly in required mode.
3. Switch to `OIDC_MODE=optional` and restart Campfire.
4. Ask each existing user to sign in locally, open their profile, and use **Connect Single Sign-On**.
5. Sign out and confirm that each connected account can sign in through OIDC. Open each push-enabled browser once so its existing subscription is rebound to the current session. Ambiguous or multi-session pre-upgrade capabilities remain quarantined and receive no notifications until a browser resynchronizes them; required-mode activation removes any that remain unresolved.
6. Resolve any active accounts whose email addresses differ only by case; ambiguous emails fail closed.
7. Set `OIDC_BREAK_GLASS_EMAIL` to one existing administrator with a tested, operator-known local password.
8. Test both SSO and the **Administrator recovery sign-in** link in a private browser window.
9. Schedule a coordinated activation window, set `OIDC_MODE=required`, and restart Campfire. Until activation succeeds, ordinary HTTP and Cable requests return `503` without deleting existing sessions. Health checks and the narrow sign-in/OIDC verification surface remain available.
10. During one 15-minute window, every active non-recovery user must complete an OIDC sign-in using the exact required-mode configuration, and at least one administrator must do so. A callback may finish on the maintenance page while the application remains blocked. Run `bin/rails oidc:check`; if any proof expires, repeat the affected sign-in.
11. With traffic still stopped, run `bin/rails oidc:activate_required` interactively. For non-interactive automation, provide `OIDC_BREAK_GLASS_PASSWORD` only for that process. Activation verifies the recovery password and fresh per-identity coverage, then atomically revokes incompatible sessions and unresolved legacy push subscriptions and records the configuration fingerprint.

The recovery exception resolves to exactly one active administrator using a
case-insensitive email match at activation. Campfire then stores that user as
the recovery binding; changing the environment variable does not silently
change who can use recovery. A replacement is bound atomically only after the
new configuration passes fresh activation using the replacement
administrator's password. Zero or multiple candidate matches block activation.
Other administrators cannot bypass required SSO. Pre-existing password sessions,
including sessions for the recovery administrator, are rejected; recovery
requires a fresh password sign-in and receives the same bounded lifetime as an
OIDC session.

Required mode also disables password-based join links and automatic session
transfer links. JIT provisioning is the supported way to create new accounts
while required mode is active.

Changing issuer or subject identifiers is not an automatic account migration.
Return to optional mode and explicitly relink accounts before changing the
configured issuer or client ID. Changing the client ID is not a transparent
credential rotation because it changes provider provenance for every link.
Secret, allowed-host, redirect, proxy, or lifetime rotation makes required mode
unready without invalidating identity links. Use the still-available OIDC
sign-in surface to obtain fresh proof for every active identity during one
15-minute window, then run activation again; old-configuration sessions are
revoked atomically.
JIT-created users have no known local password, so an issuer
change requires an administrator-managed recovery plan.

### Security behavior

Campfire requires an ID token and validates its signature algorithm, issuer,
subject, audience, authorized party, expiration, issue time, optional
not-before time, and nonce. The UserInfo subject must match the ID-token
subject. A string or singleton-array audience must identify only Campfire's
client, and any `azp` must equal that client. Each OAuth state has an expiring server-side record that is atomically
consumed once and bound to the initiating browser, exact OIDC configuration,
intended operation, and Campfire session. Nonce and PKCE values are accepted
only from that record, never from callback parameters.

When an ID token has a `sid`, Campfire stores it only on the resulting
federated session, bound to that session's immutable identity and provider
configuration. A Back-Channel Logout Token is accepted only after its compact
JWS signature is checked with the configured exact algorithm and a key fetched
from exact-issuer discovery and JWKS endpoints through the same allowlisted,
DNS-pinned transport used for sign-in. Campfire requires exact `iss`, an `aud`
whose only value is its client ID, a matching `azp` whenever that claim is
present, recent integer `iat` and `exp` claims, a bounded `jti`, the standard
back-channel logout event with an empty object value, no `nonce`, and at least
one usable `sid` or `sub`. Duplicate JSON members, duplicate key IDs,
inconsistent `sid`/`sub` pairs, ambiguous provider session IDs, stale tokens,
and token replay are rejected. A `sid` token revokes only sessions with that
exact provider binding; a subject-only token revokes all federated sessions for
the exact linked `(issuer, sub)`. Unknown and already-revoked targets succeed
without revealing account or provider details, while reuse of the same signed
token is rejected.

Campfire stores the signed ID-token `iat` on each federated session and keeps
short-lived issuer-scoped, digested `sid` and `sub` logout watermarks. Callback
session creation and logout watermark/session deletion use the same database
guard rows in one transaction. Whichever commits last therefore observes the
other: logout after callback deletes the session, while callback after logout
rejects an ID token issued at or before the watermark. This also covers a first
JIT login for a subject that is not linked yet. Delayed older logout tokens do
not delete sessions issued later than that token, and cannot lower an existing
watermark. Replay evidence and watermarks have bounded expiry and incremental
cleanup; no ID token or raw provider identifier is retained in that storage.

The provider-revocation migration cannot recover an authentic provider `sid` or
signed ID-token `iat` for federated sessions created by the preceding schema.
It therefore terminates those OIDC sessions during upgrade instead of inventing
ordering provenance. Their session-bound Web Push subscriptions are removed at
the same time and are recreated after sign-in. Local sessions are preserved.
Users with an existing OIDC session must sign in again after this migration.

Federated sessions have an absolute expiration. Expiration and ordinary logout
close WebSocket connections identified by that exact session. Database cleanup
failure cannot prevent the expiry close. Cable commands and outbound
transmissions also recheck the database session, so a Redis disconnect failure
or a later required-mode readiness failure does not leave a connection
authorized. The browser warns five minutes before expiry. The current rich-text
draft and unconfirmed text submissions are
stored separately when browser session storage is available. Pending submissions
retain their original client message IDs and remain visible with a retry action,
so a newer draft does not silently replace an older ambiguous send. Otherwise the
warning tells the user to copy unsent text. Selected attachments remain in memory
and must be sent before expiry or chosen again after sign-in. Web Push subscriptions
are bound to a current session, synchronized unless that session and capability were
already synchronized within the preceding 30 seconds, and revalidated immediately before
network delivery. Payloads contain only a generic Campfire notice and no tenant,
room, sender, message, attachment, unread-count, or destination metadata; current
content is fetched only after authenticated navigation. Push destinations must
be public HTTPS on port 443; DNS results are checked for private and special-use
addresses and the validated address is pinned for bounded delivery. In activated `required` mode,
legacy, local, and transferred sessions are rejected. Disabling OIDC also
invalidates existing federated sessions. Campfire does not retain access
tokens, refresh tokens, or ID tokens after sign-in.

Campfire also persists a monotonic OIDC session generation. A readiness check,
session lookup, or session creation under a changed exact configuration
advances that generation. Each reconciliation destroys a bounded batch of
older sessions through the normal revocation path, including Web Push cleanup
and an Action Cable disconnect broadcast; readiness remains unavailable while
older batches remain. Returning from configuration A to B and then to A
therefore does not make cookies from the first A generation valid again. Once
the persisted fingerprint and generation are synchronized and no stale session
remains, session validation uses read-only database queries; only a mismatch or
stale-session retirement enters the serialized mutation path.

Back-channel logout removes sessions and their bound Web Push capabilities but
does not deactivate the Campfire account. Use the limited SCIM endpoint below
when disabling a person at the provider must also deactivate their Campfire
account.

Signing out of Campfire terminates the local session but does not terminate the
browser's session at the identity provider.

### SCIM deprovisioning

SCIM is disabled by default and cannot be enabled unless OIDC is also enabled.
Generate an independent random bearer credential and configure both settings:

```sh
SCIM_ENABLED=true
SCIM_BEARER_TOKEN=<output-of-openssl-rand-hex-32>
```

`SCIM_BEARER_TOKEN` must be 32 to 512 bytes using RFC bearer-token characters.
Use at least 256 bits of randomness, keep it out of URLs and logs, and rotate it
by changing the environment value and restarting Campfire. Campfire's SCIM
configuration object retains only its SHA-256 digest. Supplying a token without
`SCIM_ENABLED=true` does not expose the SCIM surface.

Configure the identity provider with base URL
`https://chat.example.com/scim/v2` and static Bearer authentication. SCIM is
pinned at boot to the exact `OIDC_ISSUER`; requests cannot choose an issuer.
The supported surface is:

- `GET /scim/v2/ServiceProviderConfig`
- `GET /scim/v2/Users/:id` using Campfire's opaque stable SCIM ID
- `GET /scim/v2/Users?filter=externalId eq "<sub>"`
- `GET /scim/v2/Users?filter=userName eq "<sub>"`
- `GET /scim/v2/Users?filter=id eq "<stable-id>"`
- `PATCH /scim/v2/Users/:id` with a standard PatchOp that replaces only `active` with the JSON boolean `false`
- `DELETE /scim/v2/Users/:id`, with the same deactivation effect
- `DELETE /scim/v2/Users/00000000-0000-0000-0000-000000000000?filter=externalId eq "<sub>"` for blind subject deprovisioning

The returned `userName` and `externalId` are the immutable OIDC subject, not an
email address. Email, display name, or other mutable profile filters are never
used to resolve an account. SCIM cannot create, link, rename, change roles, or
reactivate users; unsupported attributes or string-valued `"false"` fail
closed. Deactivation runs under the same cross-process user mutation fence as
administrator deactivation, changes account status atomically, and destroys
all of the user's sessions, Web Push capabilities, searches, and non-direct
room memberships before closing Cable connections. Repeating PATCH or DELETE
for an already inactive identity is safe. The identity also receives a durable,
one-way provider-revocation timestamp even if the user was already banned. A
later administrator unban removes the abuse ban but leaves that account
deactivated, and OIDC authentication independently rejects the revoked
identity.

Blind subject deprovisioning returns `204 No Content` for a valid subject,
whether or not an identity exists, only after atomically writing a permanent
issuer-and-subject tombstone and applying any existing account cleanup. It
therefore neither exposes subject existence nor allows a later account link or
JIT provisioning callback to recreate access. The all-zero UUID is reserved
for this operation and is not a Campfire user identifier. For the protected
required-mode recovery administrator, Campfire preserves the active local
password account and its local sessions while permanently revoking the provider
identity and destroying that identity's OIDC sessions and bound Web Push
capabilities. The blind operation still returns `204` after those revocations
commit.

Search-history recording and boost creation/removal recheck active-user and
room authorization under that same mutation fence and database transaction.
A SCIM deactivation that wins the race therefore cannot be followed by a stale
authenticated request creating those records.

SCIM cannot deactivate or alter the required-mode recovery administrator's
local password account. Rotate and activate the recovery binding through the
documented OIDC process before changing that local account. Unknown stable IDs,
identities from another issuer, bad credentials, unsupported filters, and
storage failures return SCIM-shaped generic errors without disclosing issuer,
subject, account, or credential details. SCIM
requests have a small pre-parser body ceiling and are rate- and
concurrency-limited before identity lookup; they fail closed if the rate-limit
store is unavailable. OIDC and SCIM readiness perform isolated cache write,
increment, and delete probes. SCIM readiness also creates, opens, locks, and
removes a probe in the shared user-mutation-fence directory. A later filesystem
failure during deprovisioning is returned as the same generic SCIM `503` error.
Rails parameter filtering redacts SCIM `filter` values,
but an external proxy may log the raw query string before Campfire sees it.
Configure every load balancer, ingress, CDN, and access-log pipeline in front of
Campfire to suppress or redact query strings for `/scim/v2/Users`.

### Rollback

Switching from required to optional mode on the same OIDC-capable application
version re-enables new password authentication, but sessions revoked during
activation do not return. Do not reverse the identity migration after people
have linked accounts. The provider-revocation migration is intentionally
irreversible because dropping logout or SCIM security records could restore
access; restore a tested pre-migration backup instead of attempting a
destructive schema rollback.

No older Campfire release is storage-compatible with this image's durable Redis
history. Never attach a volume written by this image to an older image: the old
Redis process starts an independent history, and returning to this image can
replay stale destructive jobs. Roll forward whenever possible.

An image rollback must instead restore the authenticated pre-upgrade archive to
a separate empty volume and boot that volume with the exact old image digest
recorded during the recovery test. Keep the current volume untouched. The
restored database, files, and old-image queue semantics then all come from the
same pre-upgrade point.

`oidc:prepare_rollback` is only a credential-quarantine primitive for a future
target explicitly documented as OIDC- and Redis-compatible. It globally removes
sessions and push subscriptions, refuses to strand JIT-provisioned or other
passwordless users, and does not make currently released older images
compatible. If a compatible rollback is abandoned, cancellation requires a
required-mode configuration, the recovery password, and explicit confirmation;
complete fresh OIDC verification and activation before restoring traffic.

Authentication failures shown to users are deliberately generic. Linking
failures return the still-authenticated user to their profile. The server log
includes the request ID, an allowlisted reason code, and exception class for
diagnosis without logging authorization codes, state values, claims, or
tokens.
