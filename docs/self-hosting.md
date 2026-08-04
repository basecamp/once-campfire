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

To run it you'll need three things:
1. a machine that runs Docker
2. a mounted volume (so that your database and file attachments are kept around between restarts)
3. some environment variables for configuration

If you'd rather build the image yourself from your own copy of the source, you can do that too:

```sh
test -z "$(git status --porcelain --untracked-files=all)"
revision=$(git rev-parse HEAD)
build_identity=$(openssl rand -hex 32)
docker build \
  --build-arg GIT_REVISION="$revision" \
  --build-arg BUILD_IDENTITY="$build_identity" \
  -t campfire .
```

Both build arguments are mandatory and validated. Build only a clean commit,
and retain the revision and random build identity beside the resulting image
digest. Rebuilding the same commit requires a new build identity.

### Mounting a storage volume

Campfire keeps its database, uploaded files, and durable Redis queue state inside
`/rails/storage`.
By default Docker containers don't persist storage between runs, so you'll want to mount a persistent volume into that location.

The simplest way to do this is with the `--volume` flag with `docker run`. For example:

```sh
docker run --volume campfire:/rails/storage ghcr.io/basecamp/once-campfire:latest
```

That will create a named volume (called `campfire`) and mount it into the correct path.
Docker will manage where that volume is actually stored on your server.

You can also bind-mount a local path. Production storage and backup destinations
must be local POSIX filesystems that support SQLite locking, `flock`, atomic
same-filesystem rename, atomic hard-link creation, regular-file and directory
`fsync`, and durable ownership changes. Network filesystems are unsupported
unless you have independently proved all of those semantics; backup and restore
commands fail closed when a required durability operation is unavailable.

Production always uses `/rails/storage` and
`/rails/storage/db/production.sqlite3`. `DATABASE_URL`,
`CAMPFIRE_STORAGE_PATH`, `CAMPFIRE_DATABASE_PATH`, and an alternate installation
marker path are rejected in production so migration authorization cannot inspect
one database while Active Record mutates another.
On Linux and macOS, each file-backed Active Record connection also identifies
the newly opened SQLite main-file descriptor and requires its device and inode
to match that canonical database before migration or backup code can mutate it.
Every guarded mutation boundary also asks the connection's SQLite VFS whether
the open main file was moved or replaced. Ambiguous or unavailable native
identity verification fails closed in production; canonical snapshot comparison
remains an additional check around guarded mutations.

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

In this built-in TLS mode, Thruster replaces client-supplied forwarding headers
and passes one client address to a loopback-only Puma listener. Do not enable
`FORWARD_HEADERS` or expose the internal Puma target port. OIDC deployments in
this mode require public HTTPS port 443. Campfire honors Thruster-prefixed TLS
settings, validates and fingerprints their effective values, and rejects an
empty or incompatible override. The pinned Thruster release rejects arbitrary
HTTP Host values instead of redirecting them.

If you are terminating SSL in some other proxy in front of Campfire, or aren't using SSL at all (for example, if you want to run it locally on your laptop), then you should set `DISABLE_SSL=true` instead and just publish port 80:

```sh
docker run --publish 80:80 --env DISABLE_SSL=true ...
```

When OIDC is enabled, browsers must still reach Campfire over HTTPS. A
TLS-terminating proxy must pass the original HTTPS scheme (normally through
`X-Forwarded-Proto: https`); OIDC and authentication cookies are `Secure` in
production. Set `OIDC_TRUSTED_PROXY_CIDRS` to the comma-separated CIDRs of the
proxies that connect directly to Campfire, and prevent clients from reaching
the application port except through those proxies. Campfire ignores forwarded
HTTPS from other addresses. Also set `TLS_DOMAIN` to include the public OIDC
hostname; `DISABLE_SSL=true` keeps Thruster disabled, so the proxy remains the
TLS terminator. Proxies serving a non-default HTTPS port must send the exact
port in `X-Forwarded-Port` and set the same value in `HTTPS_PORT`. Campfire
installs that validated host and port as the downstream request authority so
Rails CSRF and Action Cable origin checks use the browser's canonical origin.
Do not use a broad client network as a trusted proxy range. Plain HTTP with
`DISABLE_SSL=true` is not an OIDC deployment mode.

#### Error reporting (optional)

To enable error reporting to Sentry in production, supply your DSN in the `SENTRY_DSN` environment variable.
To disable Sentry initialization entirely, set `SKIP_TELEMETRY=true`.

#### Single sign-on (optional)

Campfire supports OpenID Connect single sign-on in addition to, or instead of,
local password authentication. Configuration, identity-provider requirements,
and rollout guidance are covered in the [SSO guide](sso.md).

### Example

Putting it all together, here's a complete `docker run` invocation:

```sh
docker run \
  --name campfire \
  --stop-timeout 70 \
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
    stop_grace_period: 70s
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

Campfire allows up to 60 seconds for in-flight requests and jobs to stop, then
up to 5 seconds for forced process-group cleanup. Keep the container runtime's
stop grace period above that total. `CAMPFIRE_SHUTDOWN_TIMEOUT` can raise the
internal graceful period for installations with longer bounded jobs.

Web and job process defaults use the container's available CPU quota and are
capped at four processes each. Set `WEB_CONCURRENCY` and `JOB_CONCURRENCY`
explicitly only after sizing memory and workload on the target host.

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
docker pull ghcr.io/basecamp/once-campfire:latest
```

Any pending database migrations run automatically when the container boots.
Database preparation completes before web, Redis, or worker processes start,
so workers never run new code against an old schema. Before an upgrade that
adds authentication or identity data, create and verify a backup using the
guarded procedure below rather than relying on application rollback as a
data-recovery mechanism. The first upgrade across the identity migration fails
before database preparation unless the stopped source volume has a fresh,
authenticated recovery authorization for the exact target image.
The identity migration's destructive `down` path is unavailable in production:
the upgrade receipt does not authorize a downgrade, and Campfire has no separate
authenticated rollback-archive and target-build contract. Restore the tested
pre-upgrade generation to a new volume instead.

### Backups

Do not copy the live SQLite or Redis files. A recoverable generation must be
created while the source volume is quiesced, with no web, worker, or Redis
process using it. The generation contains its own SQLite snapshot, uploaded
files, Redis state, an installation marker, and an authenticated manifest.

Generate a dedicated backup authentication key once, then generate a separate
256-bit archive-encryption key with an explicit operator-assigned key ID:

```sh
openssl rand -base64 32
docker run --rm ghcr.io/basecamp/once-campfire:latest \
  script/admin/generate-backup-encryption-key prod-backups-2026-08
```

Store the first generated value as `BACKUP_AUTHENTICATION_KEY` in a secret
manager outside the Campfire volume and outside the backup destination. Store
the two values printed by the admin command as `BACKUP_ENCRYPTION_KEY_ID` and
`BACKUP_ENCRYPTION_KEY`; the latter is
strict Base64 for exactly 32 random bytes and must not equal the authentication
key. Every prepare, archive, verify, extract, install, and guarded-upgrade
authorization command requires the authentication key. Production archive,
extract, and encrypted guarded-upgrade checks additionally require the
encryption key and ID. The commands
remove encryption-key variables from their own environment immediately after
decoding them, and backup helper subprocesses receive neither key.

Keep all of these secrets outside both the source volume and archive custody.
Losing the authentication key makes a generation unverifiable; placing it
beside an archive permits a hostile rewrite. Losing an encryption key makes its
archives undecryptable; placing it beside an archive removes confidentiality.
The encryption key ID is non-secret and is stored in the authenticated envelope
header so restore tooling can select the right escrowed key.

For a direct Docker deployment, use the immutable digest of the currently
running image, stop Campfire, and run:

```sh
IMAGE=ghcr.io/basecamp/once-campfire@sha256:replace-with-running-digest
docker stop --timeout 35 campfire
test "$(docker inspect --format '{{.State.Running}}' campfire)" = false
test "$(docker inspect --format '{{.State.ExitCode}}' campfire)" = 0

docker run --rm \
  --volumes-from campfire \
  --env-file /path/to/campfire.env \
  --env BACKUP_AUTHENTICATION_KEY="$BACKUP_AUTHENTICATION_KEY" \
  --env CONFIRM_QUIESCED_BACKUP="CAMPFIRE IS STOPPED" \
  "$IMAGE" script/admin/prepare-backup

backup_id="20260731T120000Z-0123456789abcdef" # Use the printed value.
fingerprint="replace-with-printed-installation-fingerprint"
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --group-add 1000 \
  --volumes-from campfire:ro \
  --volume "$PWD":/archives \
  --tmpfs "/backup-plaintext:rw,nosuid,nodev,noexec,size=8g,uid=$(id -u),gid=$(id -g),mode=0700" \
  --env BACKUP_AUTHENTICATION_KEY="$BACKUP_AUTHENTICATION_KEY" \
  --env BACKUP_ENCRYPTION_KEY_ID="$BACKUP_ENCRYPTION_KEY_ID" \
  --env BACKUP_ENCRYPTION_KEY="$BACKUP_ENCRYPTION_KEY" \
  --env BACKUP_PLAINTEXT_TMPDIR=/backup-plaintext \
  --env EXPECTED_INSTALLATION_FINGERPRINT="$fingerprint" \
  --env EXPECTED_ENVIRONMENT=production \
  "$IMAGE" script/admin/archive-backup \
  "/rails/storage/backups/$backup_id" /archives
```

Prepared generations remain owner-writable but grant read and directory
traversal to the image runtime group. Keep the host UID and GID so the encrypted
archive is host-owned, and add image runtime GID `1000` to read the source
generation without making it world-readable or running the archiver as root.
The encrypted archive is published with mode `0640`.

Size the private tmpfs above the compressed tar plus the extracted verification
copy; `8g` is only an example and must be adjusted for the installation. If RAM
and swap cannot safely hold that workspace, configure
`BACKUP_PLAINTEXT_TMPDIR` as a private mode-`0700` directory on a separate
encrypted scratch mount and securely retire that mount after the operation.
Production refuses a workspace on the archive destination's source mount and
fails closed when Linux mount identity cannot be verified. Without an explicit
setting, the command uses a trusted private or root-owned sticky system temp
root, but a dedicated tmpfs is preferred.

Docker Compose operators can run the same two scripts through `docker compose
run --rm --no-deps web`, mounting an off-volume `/archives` directory and a
private tmpfs for the second command. Do not restart Campfire until both
commands succeed.

On every normal boot, Campfire removes the previous `clean-shutdown.json`
proof before database preparation or any writer starts. It publishes a new
proof only after every process group has stopped, Redis has exited successfully,
and all Redis persistence files and directories have been flushed. A nonzero
Redis exit, graceful-shutdown timeout, forced termination, or container
`SIGKILL` leaves no usable proof. For current-format storage, `prepare-backup`
requires a valid proof; `CONFIRM_QUIESCED_BACKUP` and the legacy controls cannot
override a missing or invalid one.

`prepare-backup` publishes `storage/backups/<backup-id>/` and atomically updates
`latest`. It never deletes an older generation. Retention is an explicit
operator responsibility after off-machine custody and a tested restore have
been confirmed. Record the JSON output, immutable image digest, backup ID,
installation fingerprint, environment, schema version, authentication key ID,
and encryption key ID outside the source volume.

Before snapshotting, preparation requires a complete SQLite WAL checkpoint and
records normalized sidecar constraints plus a canonical database hash. If
preparation fails after creating a hidden generation staging directory, that
directory is preserved rather than recursively deleted. Inspect the reported
exact path, confirm it is disposable staging, and remove only that path before
retrying.

The running image and every backup, archive, extraction, installation, and
migration operation take two locks. A stable lock under
`CAMPFIRE_OPERATION_LOCK_ROOT` is keyed by the target's absolute textual path,
so replacing the target or its parent cannot create a second lock domain in the
same container. `.campfire-operation.lock` inside the mounted target gives
separate containers the same lock inode even though their stable roots are
process-private. The image provisions a root-owned sticky lock root and sets
`CAMPFIRE_OPERATION_LOCK_ROOT` for both UID 1000 and one-off commands run with a
host UID. Non-image production deployments must set it to an existing canonical
directory that is either owned by the runtime user with mode `0700`, or owned by
root with mode `1777`. It must be outside any target or parent that an operation
can replace. Containment is checked against the canonical physical target parent
and lock root, so a symlinked ancestor cannot hide the root inside the replaceable
tree. There is no fallback lock namespace.

The kernel `flock`, not the text left in a file, determines ownership. Do not
delete a lock file or the configured lock root to resolve contention. Stop the
process holding the directory and rerun the exact operation. The target-local
reserved lock file persists as operational metadata and is ignored when
checking whether a disposable extraction or installation target contains
restored data.

`archive-backup` writes one self-contained file:

```text
campfire-<backup-id>.campfire-backup
```

The versioned binary envelope uses AES-256-GCM with a fresh 96-bit random nonce
and a 128-bit tag. Its bounded header contains only format and algorithm fields,
the explicit encryption key ID, nonce, and encrypted-payload length; the entire
header is authenticated as additional data. The tar stream and its HMAC
statement are both inside the ciphertext, so internal filenames, the manifest,
installation and environment metadata, and archive digests are not exposed.
The complete encrypted payload, including its bundle header and HMAC statement,
is limited to 32 GiB, safely below GCM's single-message counter limit.
The inner statement still authenticates the exact tar bytes and binds the
backup ID, installation, environment, application/schema version, and HMAC key
ID as defense in depth after GCM verification. An adjacent unkeyed checksum is
not a substitute. Encryption is implemented by Ruby OpenSSL inside the image;
it does not depend on an external encryption binary, cloud KMS, or network call.

Archive publication is retry-safe. It first writes the envelope to an
authenticated, backup-specific hidden staging directory and then publishes the
single envelope. Plaintext tar data and extracted verification bytes stay in
the private `BACKUP_PLAINTEXT_TMPDIR` workspace on a source mount distinct from
the archive destination. The tar descriptor uses Linux `O_TMPFILE` when the
workspace filesystem supports it, so it never has a pathname and is not fsynced.
The portable fallback must briefly create a mode-`0600` name; it flushes the
empty creation, unlinks it, and flushes that deletion before its first plaintext
byte is written. The staging marker is a keyed
ownership commitment and contains no backup metadata; every named staged
payload is ciphertext. If the command is interrupted, leave all final and
staging files unchanged and rerun the exact same command. Before accepting
staged bytes or an existing publication on retry, the command decrypts into
unlinked private descriptors, checks the GCM tag and exact envelope EOF, checks
the embedded HMAC statement, extracts into a disposable private directory, and
runs the complete generation verifier against its manifest, database, and
payload. Publication uses no-clobber hard links, and an independently created
final name is accepted only when its bytes exactly match the authenticated
staged file. Unknown staging, symlink, hard-link, or conflicting final paths are
preserved and rejected. A completed matching envelope is an idempotent success.

#### Encryption-key escrow and rotation

Generate encryption keys on a controlled host, escrow the Base64 value offline,
and record its non-secret ID with every backup inventory. Use access controls
that require more than the archive custodian alone to retrieve the key, and
periodically test recovery from the escrowed copy. Do not store keys, recovery
JSON, shell history containing keys, or key-export files in `/rails/storage`, in
the archive directory, or in the same object-store account as the archive.

To rotate, generate a new ID and key, make them the active
`BACKUP_ENCRYPTION_KEY_ID` and `BACKUP_ENCRYPTION_KEY`, and retain each retired
ID/key until every archive encrypted with it has expired. New archives always
use the active pair. For a restore that may select retained keys, provide a
bounded JSON object through `BACKUP_ENCRYPTION_PREVIOUS_KEYS`:

```sh
BACKUP_ENCRYPTION_KEY_ID=prod-backups-2026-08
BACKUP_ENCRYPTION_KEY='base64-current-key'
BACKUP_ENCRYPTION_PREVIOUS_KEYS='{"prod-backups-2026-01":"base64-retired-key"}'
```

The header ID selects exactly one key; key trial loops are not used. At most 32
retired keys are accepted. You can instead restore with the archive's retired
ID/key as the active pair. After rotation, test both a new archive and one
retained old-key archive before retiring any key material.

#### Pre-upgrade backup

Before the first upgrade that introduces the identity migration, use the exact
target image digest only as a one-off backup tool against the stopped old
volume. Supplying a command overrides the image `CMD`, so `bin/boot` and
`db:prepare` do not run:

```sh
TARGET_IMAGE=ghcr.io/basecamp/once-campfire@sha256:replace-with-target-digest
docker stop --timeout 35 campfire
test "$(docker inspect --format '{{.State.Running}}' campfire)" = false
legacy_exit_code=$(docker inspect --format '{{.State.ExitCode}}' campfire)
test "$legacy_exit_code" = 0
docker run --rm \
  --volumes-from campfire \
  --env-file /path/to/campfire.env \
  --env BACKUP_AUTHENTICATION_KEY="$BACKUP_AUTHENTICATION_KEY" \
  --env CONFIRM_QUIESCED_BACKUP="CAMPFIRE IS STOPPED" \
  --env LEGACY_CAMPFIRE_EXIT_CODE="$legacy_exit_code" \
  --env CONFIRM_LEGACY_QUIESCED_BACKUP="LEGACY CAMPFIRE EXITED 0" \
  "$TARGET_IMAGE" script/admin/prepare-backup
```

The 35-second Docker stop timeout allows Campfire's 25-second graceful process
group deadline and 5-second forced-termination deadline to complete before the
container runtime sends its own `SIGKILL`. Use an equivalent timeout in Compose
or another supervisor. Legacy images cannot publish the new clean-shutdown
proof, so this is a separate compatibility path: inspect the stopped legacy
container, require `ExitCode=0`, and pass that exact result with the explicit
legacy confirmation shown above. Never use the legacy controls for a current
volume; they do not bypass current proof validation.

The tool supports the pre-identity schema and writes a small
`installation-identifier` marker that the later migration preserves. Archive
and restore that generation with the target image tools, then boot the restored
volume with the pinned old image and exercise sign-in, room history, uploads,
and jobs.

Only after that recovery test succeeds, keep the original volume stopped and
authorize its exact unchanged database for the exact target image. The encrypted
envelope must be mounted read-only from outside `/rails/storage`:

```sh
archive="campfire-$backup_id.campfire-backup"
docker run --rm \
  --volumes-from campfire \
  --group-add "$(id -g)" \
  --volume "$PWD":/archives:ro \
  --env-file /path/to/campfire.env \
  --env BACKUP_AUTHENTICATION_KEY="$BACKUP_AUTHENTICATION_KEY" \
  --env BACKUP_ENCRYPTION_KEY_ID="$BACKUP_ENCRYPTION_KEY_ID" \
  --env BACKUP_ENCRYPTION_KEY="$BACKUP_ENCRYPTION_KEY" \
  --env BACKUP_ENCRYPTION_PREVIOUS_KEYS="${BACKUP_ENCRYPTION_PREVIOUS_KEYS:-{}}" \
  "$TARGET_IMAGE" bin/boot authorize-upgrade \
  "/archives/$archive" "/archives/$archive"
```

The command retains two path positions for the guarded-upgrade interface; for
the self-contained format both must name the same envelope. Authorization
decrypts and fully verifies it without publishing the embedded tar or statement.

This writes `storage/upgrade-recovery.json`. Its authenticated receipt is valid
for 24 hours and binds the complete stopped source-state inventory, source
manifest, installation, environment, archive bytes, target image revision, and
target image build identity. Each protected workflow attempt has a distinct
build identity, so separate attempts and other images built from the same commit
do not share an authorization. Do not copy the envelope onto the Campfire
volume, override `GIT_REVISION`, edit the receipt, or modify the source volume
after authorization.

Recreate Campfire with the same immutable `TARGET_IMAGE`, original volume, and
normal environment, adding the authentication key and the matching encryption
keyring for this boot and mounting the same archive directory read-only at the
same `/archives` path. `bin/boot` rechecks the external envelope and receipt
before `db:prepare`. The later migration boundary uses the HMAC receipt that
pins the exact envelope hash rather than decoding the encryption key again; the
key environment has already been scrubbed. It removes the receipt only after
the gated migration is recorded. A missing, stale, malformed, wrong-target,
changed-database, unmounted, or changed-archive receipt stops before migration.
If startup fails while the old schema and volume still exactly match the archive,
inspect the failure and run `authorize-upgrade` again; otherwise restore the
authenticated generation into a new empty volume rather than trying to
manufacture or reuse evidence.

For example, add these flags to the normal replacement-container command for
the authorized boot:

```sh
--group-add "$(id -g)" \
--volume "$PWD":/archives:ro \
--env BACKUP_AUTHENTICATION_KEY="$BACKUP_AUTHENTICATION_KEY" \
--env BACKUP_ENCRYPTION_KEY_ID="$BACKUP_ENCRYPTION_KEY_ID" \
--env BACKUP_ENCRYPTION_KEY="$BACKUP_ENCRYPTION_KEY" \
--env BACKUP_ENCRYPTION_PREVIOUS_KEYS="${BACKUP_ENCRYPTION_PREVIOUS_KEYS:-{}}" \
"$TARGET_IMAGE"
```

#### Restoring a backup

Never extract a backup over the active volume. Keep the original volume
unchanged until a replacement has booted and passed application checks. Start
with the retained metadata, authentication key, encryption keyring, encrypted
archive, and an immutable image compatible with the backup schema:

```sh
(
  set -eu
  umask 077
  IMAGE=ghcr.io/basecamp/once-campfire@sha256:replace-with-recorded-digest
  backup_id="20260731T120000Z-0123456789abcdef" # Replace with the recorded ID.
  fingerprint="replace-with-recorded-installation-fingerprint"
  archive="campfire-${backup_id}.campfire-backup"
  restore_root=$(mktemp -d "$PWD/campfire-restore.XXXXXX")

  docker run --rm \
    --user "$(id -u):$(id -g)" \
    --volume "$PWD":/archives:ro \
    --volume "$restore_root":/restore \
    --env BACKUP_ID="$backup_id" \
    --env BACKUP_AUTHENTICATION_KEY="$BACKUP_AUTHENTICATION_KEY" \
    --env BACKUP_ENCRYPTION_KEY_ID="$BACKUP_ENCRYPTION_KEY_ID" \
    --env BACKUP_ENCRYPTION_KEY="$BACKUP_ENCRYPTION_KEY" \
    --env BACKUP_ENCRYPTION_PREVIOUS_KEYS="${BACKUP_ENCRYPTION_PREVIOUS_KEYS:-{}}" \
    --env EXPECTED_INSTALLATION_FINGERPRINT="$fingerprint" \
    --env EXPECTED_ENVIRONMENT=production \
    "$IMAGE" script/admin/extract-backup "/archives/$archive" /restore
  docker run --rm \
    --user "$(id -u):$(id -g)" \
    --volume "$restore_root":/backup \
    --env BACKUP_AUTHENTICATION_KEY="$BACKUP_AUTHENTICATION_KEY" \
    --env EXPECTED_INSTALLATION_FINGERPRINT="$fingerprint" \
    --env EXPECTED_ENVIRONMENT=production \
    "$IMAGE" script/admin/verify-backup "/backup/$backup_id"

  docker volume create campfire-restored
  docker run --rm \
    --user root \
    --mount type=volume,src=campfire-restored,dst=/rails/storage,volume-nocopy \
    --volume "$restore_root":/backup:ro \
    --env BACKUP_AUTHENTICATION_KEY="$BACKUP_AUTHENTICATION_KEY" \
    --env EXPECTED_INSTALLATION_FINGERPRINT="$fingerprint" \
    --env EXPECTED_ENVIRONMENT=production \
    --env RESTORE_UID=1000 \
    --env RESTORE_GID=1000 \
    "$IMAGE" script/admin/install-backup "/backup/$backup_id" /rails/storage
)
```

Released backups from before encrypted-envelope publication remain readable,
but only through the explicit three-input compatibility mode:

```sh
docker run --rm \
  --user "$(id -u):$(id -g)" \
  --volume "$PWD":/archives:ro \
  --volume "$restore_root":/restore \
  --env BACKUP_ID="$backup_id" \
  --env BACKUP_AUTHENTICATION_KEY="$BACKUP_AUTHENTICATION_KEY" \
  --env EXPECTED_INSTALLATION_FINGERPRINT="$fingerprint" \
  --env EXPECTED_ENVIRONMENT=production \
  "$IMAGE" script/admin/extract-backup --legacy-plaintext \
  "/archives/campfire-${backup_id}.tar.gz" \
  "/archives/campfire-${backup_id}.authentication.json" /restore
```

This mode rejects oversized archive and statement files, copies the already
plaintext legacy archive into one anonymous bounded descriptor, and verifies
its HMAC before parsing any tar entry or creating an extracted path. It never
publishes a plaintext archive; all new `archive-backup` output uses the encrypted
two-argument extraction contract shown above.

The extractor opens one independent encrypted source descriptor and rejects
symlinks and hard links. It strictly bounds and authenticates the binary header,
selects the header's exact key ID, streams decryption to descriptors unlinked
before any plaintext is written, and requires the declared ciphertext, exact
EOF, and GCM tag to match before parsing the embedded HMAC statement or tar.
Only after both GCM and HMAC verification succeed can it create generation
paths. It rejects traversal, duplicates, links, special files, and content
outside the recorded backup ID. Verification reconstructs
the image's expected schema
from its complete migration set and compares tables, columns, indexes, foreign
keys, check constraints, and virtual tables. It also checks account cardinality,
SQLite integrity, every uploaded blob, exact payload membership, and strict
Redis AOF/RDB layout and loadability.

The installer accepts only an empty destination, copies through a temporary
database name, flushes files and directories, applies ownership, and then
repeats hashes, schema checks, blob checks, Redis validation, and installation
identity checks against no-follow descriptors for the final destination bytes.
Files, directories, the restore marker, and both operation locks are chowned,
chmodded, and synced only through inode-verified no-follow descriptors; the
destination root is handed to UID 1000 last.
It requires the exact authenticated file and directory inventory and binds each
validated descriptor to the inode captured before validation. Before changing the
destination it durably creates `restore-in-progress.json`; `bin/boot` refuses
any volume where that path remains. The installer removes and flushes the marker
only after final ownership, durability, and verification checks succeed. On a
precommit failure it removes only the files it placed but deliberately preserves
the marker, so retrying the same destination also fails closed. Do not continue
after a warning or error, delete the marker, or retry into that path or volume.
Preserve the original Campfire volume, discard only the disposable failed
destination after confirming its exact name, create a different empty
destination, and rerun the full extract, verify, and install sequence.

The published image runs as UID and GID `1000`. A root restore must explicitly
set both `RESTORE_UID=1000` and `RESTORE_GID=1000`; any other requested owner is
rejected before backup files are installed. A non-root restore is accepted only
when the invoking process already has that exact runtime identity.

Launch a replacement Campfire container with `campfire-restored`, the original
image version or a newer schema-compatible image, and the original environment.
Check `/up`, `/up/oidc` when configured, sign-in, room history, an uploaded file,
and worker processing before moving traffic. Keep the original volume until the
restore has been accepted; never use it as the restore target.

Never attach a volume written by this image to an older image. Older releases
used an independent ephemeral Redis history; running one on the current volume
can lose new jobs and later replay stale destructive jobs. Image rollback means
restoring the authenticated pre-upgrade generation into another empty volume
and booting that volume with the exact recorded old image digest. Otherwise,
roll forward with the current image.
