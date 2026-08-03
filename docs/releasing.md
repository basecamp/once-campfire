## Release controls

Campfire releases have one authorized entrypoint: `bin/release VERSION` from a
clean checkout of the canonical `basecamp/once-campfire` repository on `main`.
Tag pushes and GitHub release events do not build or promote images. The script
creates or verifies a signed tag and dispatches `publish-image.yml` from the
exact current `main` SHA.

Configure these repository controls before using the release script:

- Protect `main` and require the project's normal reviews and checks.
- In branch protection, require both `Container validation (amd64)` and
  `Container validation (arm64)`; do not treat the native application test job
  as container or multi-architecture evidence.
- Restrict creation and deletion of `v*` tags to the release operators.
- Create a GitHub environment named `release`, add required reviewers, prevent
  self-review, and restrict deployment branches to `main`.
- Store the allowlisted armored tag-signing public key and its uppercase
  fingerprint as `RELEASE_TAG_SIGNER_PUBLIC_KEY` and
  `RELEASE_TAG_SIGNER_FINGERPRINT` secrets in that environment.
- Restrict workflow changes and environment-policy changes with `CODEOWNERS` or
  an equivalent ruleset.
- Keep package deletion and tag deletion unavailable to ordinary contributors.
- Provision two independently administered Object Lock buckets in different AWS
  accounts for the mandatory release-journal anchors described below. Independent
  teams must administer the accounts. Their retained object versions are the
  append-only WORM evidence; the static export host is not an anchor.

The architecture and manifest jobs both use the protected `release`
environment. Each architecture is pushed to attempt-scoped staging, signed, and
subjected to current-schema and pre-migration recovery tests. The manifest job
then verifies those exact child digests and uploads attempt-scoped final release
evidence. It does not create release aliases. Only after the successful evidence
artifact is downloadable does `bin/release` validate its digest, signatures,
children, run ID, run attempt, and per-operation dispatch nonce and idempotently create missing immutable
`vMAJOR.MINOR.PATCH` and `MAJOR.MINOR.PATCH` aliases.

### Container CI evidence

`.github/workflows/container.yml` is the registry-read-only container check for
pull requests and `main`. It has only `contents: read`, uses a digest-pinned
BuildKit daemon, QEMU image, SBOM scanner, Dockerfile frontend, runtime base,
and legacy recovery image, and never logs in or invokes a registry exporter.
Both matrix entries run on GitHub-hosted x86 runners; the `linux/arm64` build,
boot, HTTP health, request-ceiling, and recovery path therefore execute through
QEMU rather than receiving credit from an unexecuted cross-build.

For each architecture the check exports an OCI layout with max-mode BuildKit
provenance and SPDX SBOM, loads a cache-identical Docker exporter result, matches
its config digest to that layout, and checks the platform, non-root user, working
directory, command and empty entrypoint, ports, environment, OCI labels, build
identity, `/up`, oversized-request `413`, and graceful shutdown. It then invokes
`script/ci/verify-image-recovery` against the digest-pinned pre-migration image
on disposable volumes. The script covers current and legacy restore, denied
unauthorized migrations, tamper rejection, authorized upgrade, sign-in/history,
uploads, Redis state, and worker execution. Normalized inspection, SBOM,
provenance, logs, and hash-bound recovery receipts are retained for 30 days as
`container-evidence-ARCH-ATTEMPT`; the OCI archive itself is removed after its
statements and digest are recorded.

The protected release workflow repeats config, boot, health, request-limit, and
recovery checks against each exact pushed child digest. GitHub artifact
attestations bind the per-architecture build index, runnable child, and final
multi-architecture index to the exact `main` source digest and
`publish-image.yml`; `gh attestation verify` enforces that source digest, source
ref, signer workflow, and GitHub-hosted runner before release evidence is
accepted. Before migration consumes the in-volume authorization, the recovery
helper copies the exact `upgrade-recovery.json` bytes into architecture evidence
and verifies that neither backup key appears in the retained receipt. The final
staging index is assembled from the two evidenced build
indexes so its child digests and BuildKit SBOM/provenance attachments converge
with the images that were executed. Architecture evidence and the final release
evidence are retained by GitHub for 90 days only as transport and diagnostic
copies. They are not the durable reconciliation authority.

The workflow creates only attempt-scoped staging references. `bin/release`
downloads that exact attempt's evidence and records authenticated immutable
alias and `promotion_prepared` journal heads before `promotion.converge!`.
Before writing any retained evidence object, it records the operation nonce,
run ID and attempt, and exact file names, byte counts, and SHA-256 hashes as an
authenticated `workflow_evidence_pending` journal revision and reads that
revision back from both anchors. It then retains the complete bundle in the
first account and the complete bundle in the second. A retry can recover the
pending bytes from either account, complete both idempotently, and only then
replace the pending state with the final `workflow_evidence` journal contract.
Every authenticated journal revision and its content-addressed head are
synchronously retained and read back from both Object Lock anchors before the
release driver can make the next external mutation. GitHub artifacts prove what
CI checked; the live registry probes and dual anchors prove the separate
production controls used by the release driver.

The dispatch phase generates a 256-bit operation nonce and authenticates it in
the journal before calling GitHub. The protected workflow must declare the exact
required string inputs `release_tag`, `release_sha`, and `operation_nonce`, set
its run name to
`Campfire release ${{ inputs.release_tag }} ${{ inputs.release_sha }} ${{ inputs.operation_nonce }}`,
and copy the nonce into version 1 release evidence. Run discovery accepts exactly
one run with that title, source SHA, branch, event, workflow name, and successful
attempt. The downloaded evidence must have the exact top-level and nested key
schemas enforced by `bin/release`; extra keys are rejected rather than ignored.

The release evidence artifact is an exact flat inventory. It contains the
release statement, both recovery receipts and upgrade receipts, architecture
inspection/SBOM/BuildKit provenance, parent and runnable provenance bundles and
verification results, index provenance and verification, and the separate
promotion-requirements statement. Every named file is a fixed regular file and
is hash-bound from `release-evidence.json`; the recovery, upgrade, signed
provenance, and promotion hashes are cross-checked against the actual bytes.
After validation and source revalidation, `bin/release` stores every byte under
content-addressed per-operation keys with COMPLIANCE retention in both Object
Lock accounts, then authenticates the exact byte counts and SHA-256 values in
the journal. Reconciliation restores and revalidates those bytes from both
anchors, so it does not download latest-attempt evidence or depend on GitHub's
90-day artifact lifetime.

The final artifact's flat filenames are exactly:

```text
release-evidence.json
promotion-requirements.json
index-provenance.bundle.jsonl
index-provenance-verification.json
recovery-amd64.json
recovery-arm64.json
upgrade-recovery-amd64.json
upgrade-recovery-arm64.json
container-validation-amd64.json
container-validation-arm64.json
sbom-amd64.spdx.json
sbom-arm64.spdx.json
buildkit-provenance-amd64.json
buildkit-provenance-arm64.json
parent-provenance-amd64.bundle.jsonl
parent-provenance-arm64.bundle.jsonl
runnable-provenance-amd64.bundle.jsonl
runnable-provenance-arm64.bundle.jsonl
parent-provenance-verification-amd64.json
parent-provenance-verification-arm64.json
runnable-provenance-verification-amd64.json
runnable-provenance-verification-arm64.json
```

### Operator configuration

Set these variables in the release operator's environment:

```sh
RELEASE_TAG_SIGNER_FINGERPRINT=0123456789ABCDEF0123456789ABCDEF01234567
RELEASE_COSIGN_IDENTITY=https://github.com/allowlisted/once-release-workflow
RELEASE_JOURNAL_AUTHENTICATION_KEY=replace-with-retained-base64-key
RELEASE_JOURNAL_ANCHOR_PROVIDER=aws
RELEASE_JOURNAL_ANCHOR_1_PROFILE=campfire-release-anchor-primary
RELEASE_JOURNAL_ANCHOR_1_ACCOUNT_ID=111111111111
RELEASE_JOURNAL_ANCHOR_1_BUCKET=campfire-release-anchor-primary
RELEASE_JOURNAL_ANCHOR_1_PREFIX=campfire/release-journal
RELEASE_JOURNAL_ANCHOR_2_PROFILE=campfire-release-anchor-secondary
RELEASE_JOURNAL_ANCHOR_2_ACCOUNT_ID=222222222222
RELEASE_JOURNAL_ANCHOR_2_BUCKET=campfire-release-anchor-secondary
RELEASE_JOURNAL_ANCHOR_2_PREFIX=campfire/release-journal
RELEASE_JOURNAL_EXPECTED_ANCHOR_SET_SHA256=replace-with-protected-64-character-digest
```

`RELEASE_TAG_SIGNER_FINGERPRINT` must identify the GPG key allowed to sign
Campfire tags. `RELEASE_COSIGN_IDENTITY` identifies the keyless signer used for
the secondary registry. `RELEASE_REMOTE` may select another local remote name,
but that remote must still resolve to `basecamp/once-campfire`; repository
identity is not caller-selectable.

Generate `RELEASE_JOURNAL_AUTHENTICATION_KEY` with `openssl rand -base64 32`
and retain it in the release operator's secret manager. It is independent of
the public random lock ID and must remain the same for every retry or
reconciliation of retained release state. Do not place it on the static export
host or in release artifacts. Losing it makes an interrupted release journal
unverifiable and therefore unrecoverable by automation. Because authenticated
terminal tombstones are retained for audit and repeat verification, keep this
key for their full retention lifetime.
`bin/release` removes this variable from its process environment before its
first subprocess is launched. The decoded key is passed only to in-process HMAC
operations; editors, Git, GitHub CLI, Docker, Cosign, and SSH never inherit it.

AWS CLI v2 is a mandatory release-host prerequisite. Production releases set
`RELEASE_JOURNAL_ANCHOR_PROVIDER=aws`; this mode rejects both
`RELEASE_JOURNAL_ANCHOR_1_ENDPOINT_URL` and
`RELEASE_JOURNAL_ANCHOR_2_ENDPOINT_URL`. Custom endpoints are not a production
dual-AWS configuration. Every anchor subprocess also forces
`AWS_IGNORE_CONFIGURED_ENDPOINT_URLS=true`, so global, service, and profile
endpoint settings cannot redirect STS or S3. The two configured profile
names and 12-digit account IDs must differ. Each profile's live
`sts get-caller-identity` result must equal its configured account, and every S3
request supplies that account as `--expected-bucket-owner`. Each bucket must
have versioning `Enabled` and Object Lock `Enabled`. The non-production
`s3-compatible` provider requires a distinct explicit HTTPS endpoint for each
anchor. Its S3 origin is supplied only with the higher-precedence command-line
`--endpoint-url`; configured endpoints remain ignored, and STS uses the AWS
default endpoint. A service that cannot implement the AWS CLI checksum, version,
conditional-put, owner, and Object Lock APIs fails closed.

The anchor-set identity is canonical JSON over the provider, both account IDs,
bucket names, prefixes, endpoint policy, the mandatory configured-endpoint
suppression flag, and endpoint origins. Profiles are
credential selectors and are deliberately not identity fields. After filling in
the real production values, calculate the digest once:

```sh
RELEASE_JOURNAL_EXPECTED_ANCHOR_SET_SHA256="$(
  bundle exec ruby -Ilib -rrelease_object_lock_anchors \
    -e 'puts ReleaseObjectLockAnchors.anchor_set_digest_from_env!'
)"
printf '%s\n' "$RELEASE_JOURNAL_EXPECTED_ANCHOR_SET_SHA256"
```

Store that printed value in a protected release-environment secret or an
equivalently controlled operator configuration. The release operator must not
be able to replace the expected digest while changing accounts, buckets, or
prefixes. `bin/release` persists the full descriptor at phase zero and compares
it before reconciliation or another mutation. The protected digest blocks a
fresh namespace, while a global retained operation catalog in each configured
prefix records every release operation and exposes deletion of the matching
local operation, including deletion of its complete local history.

The release role needs STS identity and the S3 bucket/versioning, Object Lock,
version-list, object-read, retention-read, and object-write operations used by
`bin/release`. Do not grant retention bypass. The script deliberately attempts
a version-specific delete after publication and requires rejection. It also
reissues the content address with `If-None-Match: *` and requires rejection, so
an implementation that accepts a second version cannot qualify. AWS CLI child
processes receive only `HOME`, `PATH`, explicit AWS config/credential file and
CA paths, and locale settings; ambient AWS keys, GitHub tokens, journal keys,
and application secrets are removed. Configure credentials in the named
profiles rather than environment variables.

Provision each bucket from its independently administered account before
calculating the anchor-set digest. The following is the complete bucket-side
sequence for a chosen non-`us-east-1` region; run it once with that account's
administrator profile and substitute the protected production bucket name:

```sh
AWS_PROFILE=campfire-release-anchor-primary-admin
AWS_REGION=us-west-2
BUCKET=campfire-release-anchor-primary

aws --profile "$AWS_PROFILE" --region "$AWS_REGION" s3api create-bucket \
  --bucket "$BUCKET" \
  --create-bucket-configuration "LocationConstraint=$AWS_REGION" \
  --object-lock-enabled-for-bucket
aws --profile "$AWS_PROFILE" s3api put-bucket-versioning \
  --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws --profile "$AWS_PROFILE" s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws --profile "$AWS_PROFILE" s3api get-bucket-versioning --bucket "$BUCKET"
aws --profile "$AWS_PROFILE" s3api get-object-lock-configuration --bucket "$BUCKET"
```

Repeat in the second account with its own administrator, release role, bucket,
and preferably a separate region. Grant the named release role only
`sts:GetCallerIdentity`, `s3:ListBucketVersions`, `s3:GetBucketVersioning`,
`s3:GetBucketObjectLockConfiguration`, `s3:GetObject`, `s3:GetObjectVersion`,
`s3:GetObjectRetention`, `s3:PutObject`, `s3:PutObjectRetention`, and
`s3:DeleteObjectVersion` on the configured bucket/prefix. The last permission is
intentional: the live version-specific delete must reach S3 and be rejected by
COMPLIANCE retention rather than fail because the caller lacks delete authority.
Do not grant `s3:BypassGovernanceRetention`, bucket deletion, lifecycle mutation,
or policy mutation. Independently controlled bucket policy and organization SCPs
must prevent the release role and repository administrators from changing those
controls. Bucket creation, independent accounts, protected secret management,
IAM separation, SCPs, and registry policy are infrastructure prerequisites;
application code can verify their observable behavior but cannot establish them.

Every revision is stored as its exact authenticated JSON bytes and as a
deterministic head statement under a SHA-256-derived release namespace. Both
objects carry a server SHA-256 checksum and explicit per-object `COMPLIANCE`
retention through at least 2,557 days after the authenticated release
`created_at`. Reads select the exact immutable version ID, download and hash the
bytes, verify the server checksum and metadata, and read the retention mode and
date. Bucket default retention may be absent or longer; it cannot weaken this
per-object requirement.

The Dockerfile frontend, Ruby base image, workflow service images, and every
third-party GitHub Action are committed at verified immutable digests or full
commit IDs. `script/ci/verify-release-policy` enforces that policy in CI, the
protected image workflow, and `bin/release`. Updating one of these dependencies
requires resolving the desired tag through its registry or source API, checking
the multi-architecture index and children, and committing the observed digest;
never substitute a guessed digest or an architecture-specific child digest.

There is no registry-policy acknowledgement variable. For each registry,
`bin/release` first writes the unique
`release-mutability-control-OPERATION_ID` tag at the verified release index and
successfully overwrites it with a distinct recovery-evidenced build index. That
authenticated successful control write proves current write authority,
connectivity, and mutable-control policy. The two source manifests are inspected
and must have the same supported index media type.

The driver then exercises every real exact alias, not a differently named proxy.
It compare-reads an alias, seeds a missing alias with the release index, attempts
to replace it with the distinct same-media-type index, and reads the alias twice.
The command must return a recognizable server-side immutable-tag denial and both
reads must preserve the release digest. Authentication failures, authorization
failures, timeouts, TLS or network errors, unsupported operations, unknown
manifests, signals, and arbitrary nonzero exits are not immutability evidence.
The journal retains the mutable-control observations and, for every actual
alias, the classified rejection, exit status, output hash, and preserved digest;
that evidence is retained in both Object Lock accounts before promotion.

Both GHCR and `registry.once.com` must provide an atomic no-overwrite policy for
the actual exact aliases: GHCR `vMAJOR.MINOR.PATCH` and
`MAJOR.MINOR.PATCH`, and secondary-registry `MAJOR.MINOR.PATCH` and the
40-character release-SHA tag. The `release-mutability-control-*`, attempt/build
staging, and moving channel namespaces must remain mutable; exact aliases must
not. Restrict writes and policy administration to independently controlled
release principals, disable package/tag deletion for those principals, and
retain exact aliases for the release retention period.

Docker Registry and Buildx expose no portable conditional create/CAS for a tag.
Testing the exact alias and re-reading around every write minimizes the race, but
only the registry's atomic server-side no-overwrite rule closes it. That rule,
its coverage of each alias namespace, deletion prevention, and separation of
policy administrators are hard infrastructure prerequisites that this code can
test but cannot create. A registry without those controls is unsupported for
production releases.

An existing signed tag, draft or public release, or release asset is never
adopted into newly created history. `RELEASE_RESUME_SHA` is rejected because it
cannot distinguish a legitimate preexisting tag from complete authenticated
history deletion. Existing external state requires explicit reconciliation and
surviving authenticated lock, pending, or terminal-tombstone state.
Every live GitHub release read is checked against authenticated publication
state. Promotion accepts `public` only when an in-flight, settled, completed, or
terminal journal transition proves the exact `draft` to `public` mutation. The
driver rereads the release inside the fenced mutation boundary and requires it
to remain a draft before issuing the publication command, so a concurrent
external publication is rejected rather than adopted as convergence.

### Interrupted releases

The static export host stores the durable release lock directory. A separate
SSH-held live-owner lock, with a new process identity for every invocation,
serializes initial releases, completion, and rollback. Losing that SSH process
invalidates the invocation; a second reconciler cannot mutate while the first
one owns it.

Before the tag or any other external resource is changed, the script atomically
publishes a complete authenticated phase-zero directory. Its non-secret
operation ID identifies durable state; only
`RELEASE_JOURNAL_AUTHENTICATION_KEY` authenticates it. Phase zero includes the
complete release-notes content and retains the exact source ZIP and checksum as
fixed regular side files whose names, byte counts, and SHA-256 digests are bound
by the journal. A different operator host therefore rematerializes those exact
bytes instead of regenerating an archive before continuing. The journal records
the exact four-field Object Lock release identity (`repository`, `version`,
`tag`, and `sha`) and never adds workflow fields to it. The original workflow
run ID, attempt, and operation nonce are stored in a separate authenticated
`workflow_run` identity. The journal also records immutable artifacts, each moving
channel's previous and target values, every completed step, the current phase,
and a monotonic revision.

Every journal update is an immutable authenticated history entry. Its filename
and HMAC bind the release operation ID, monotonically increasing revision,
prior entry digest, current entry digest, and publishing invocation. The entry
is streamed to a unique keyed staging name, checked for its exact byte count and
SHA-256, flushed, and published with a hard link that fails if the final history
path already exists. The staging link is then removed; no prior history file is
renamed, replaced, or deleted.

The live-owner record pins both the live-lock inode and a separate stable
state-lock inode. History publication holds the state `flock` while it rechecks
the exact predecessor and performs the no-replace hard link. Every reader holds
the same state lock while enumerating all entries, authenticates every entry,
requires exactly one unbroken chain beginning at phase zero, rejects forks,
gaps, and duplicate revisions, and selects the unique highest revision. No
mutable head or convenience pointer is authoritative. Two writers based on one
revision may leave two successor files; that fork is preserved and blocks both
success and reconciliation until it is investigated. It is never resolved by
choosing the newest-looking file.

An HMAC chain alone has no independently observable head, so each local head is
also a content-addressed Object Lock statement in both independent accounts.
The genesis revision also creates one content-addressed entry in each anchor's
global operation catalog. It binds the protected anchor-set digest, complete
four-field release identity, operation ID, genesis history digest, creation
time, and retention. Duplicate operations for one repository/version/tag slot,
catalog overwrite versions, delete markers, cross-anchor catalog disagreement,
or a catalog entry with no matching local operation all fail closed.
On every retry or reconciliation, `bin/release` enumerates immutable versions in
both head namespaces, validates each contiguous chain and retained revision,
and compares their highest revisions with local authenticated history before
recovery cleanup or another release mutation. An anchored revision above the
local head proves suffix deletion. Any anchored head when no matching active,
pending, or terminal-tombstone state survives proves whole-history deletion.
Anchor disagreement, a delete marker, another version at a content address, or
one unavailable account blocks the release; history is never reconstructed from
public tags, releases, assets, or an anchor.

A crash therefore leaves the prior complete history plus either an
authenticated staging file or a complete immutable successor. Recovery removes
only a keyed staging link whose exact bytes and inode relationship prove whether
the no-replace publication occurred; it never removes a history entry.
Authenticated phase-zero pending directories and retained ZIP/checksum files
remain subject to the same exact path, byte, digest, link-count, and ownership
checks before recovery. A partial artifact stream can be removed only while it
is still a provably unpublished, independently linked pending file.
Do not edit or manually remove live-owner, live-lock, state-lock,
operation-lock, pending, staging, or terminal-tombstone paths. An invalid
authentication code, unexpected entry, channel value, or changed immutable
evidence requires investigation; the script stops before making another channel
change.

On retry, `bin/release` authenticates terminal tombstones and phase-zero pending
directories. Terminal tombstones are retained as audit and recovery records;
matching state is atomically restored only for explicit reconciliation.
If an interruption left the new immutable head in only one anchor, retry accepts
that state only when it exactly matches the highest local authenticated
revision, publishes the missing content address to the other account, and
verifies both before continuing. It never chooses between divergent heads.
Incomplete staging is cleaned only when its keyed name, exact path types,
content digest, link count, and unchanged authenticated history prove it is not
an independent published entry. Unknown or unauthenticated state is preserved
and blocks release.

Before a moving channel, immutable alias, staging reference, or signature
command is launched, the journal records an authenticated
`mutation_in_flight` token and exact target. The child runs in its own process
group while `bin/release` monitors the SSH live-owner process. If ownership is
lost, the child process group is killed and waited for, but the authenticated
marker is deliberately left unresolved because a request already accepted by a
remote service could still arrive. A launched child that exits without a
verified target leaves the same unresolved state. Journal publication SSH
children are monitored the same way while staging and hard-linking immutable
history entries.

Once the journal exists, resume only through reconciliation. Check out the
release tag's exact commit and use the original successful protected
`workflow_dispatch` run ID:

```sh
RELEASE_RECONCILE_SHA=<40-character-release-sha> \
RELEASE_RECONCILE_RUN_ID=<original-workflow-run-id> \
RELEASE_RECONCILE_RUN_ATTEMPT=<original-workflow-run-attempt> \
RELEASE_RECONCILE_ACTION=complete \
bin/release MAJOR.MINOR.PATCH
```

A new release must start at the fetched current `main`; setting
`RELEASE_RECONCILE_SHA` never authorizes a new release from stale history.
For an interrupted release, reconciliation may continue after `main` advances
only when the requested SHA equals checked-out `HEAD`, surviving authenticated
journal or Object Lock state proves that exact four-field release identity, the
SHA remains an ancestor of current `main`, and any existing local and remote
signed tag still resolves to that SHA. Diverged history, a wrong reconciliation
SHA, a moved tag, or a newer stable release stops reconciliation. These same
conditions are rechecked after verification, after protected workflow evidence
is recovered, and immediately before moving-channel publication.

If reconciliation reports an unresolved mutation, first prove that the old
`bin/release` process and its child are gone and that the named remote operation
has settled. Then repeat explicit reconciliation with the exact authenticated
token it reports:

```sh
RELEASE_RECONCILE_SETTLED_MUTATION_TOKEN=<mutation-in-flight-token> \
RELEASE_RECONCILE_SHA=<40-character-release-sha> \
RELEASE_RECONCILE_RUN_ID=<original-workflow-run-id> \
RELEASE_RECONCILE_RUN_ATTEMPT=<original-workflow-run-attempt> \
RELEASE_RECONCILE_ACTION=complete \
bin/release MAJOR.MINOR.PATCH
```

Without that token confirmation, a successor does not probe, complete,
rollback, clear the journal, or report success. A wrong or stale token is
rejected. Unset it after the marker has been durably acknowledged.

`complete` moves every channel still at its recorded previous value to its
target and verifies channels already at the target. To abandon a draft release,
use the same command with `RELEASE_RECONCILE_ACTION=rollback`; it restores every
target value to its recorded previous value. The signed tag, immutable artifacts,
and draft release remain for inspection. Rollback is refused once the GitHub
release is public and is unavailable if any channel had no recorded previous
value. A public release can only be completed and verified, never restored to a
draft or retargeted. An observed public GitHub release is accepted only when the
authenticated promotion contract already records `draft` to `public` and a
surviving in-flight, settled, completed-step, or publication record explains
that exact transition. Publication before promotion preparation, or a release
returning to draft after authenticated publication, is unexpected external
state and stops reconciliation.

Reconciliation never reruns or redispatches a checkpointed protected workflow,
and never dispatches one after public completion. If authenticated state proves
that the workflow phase never started while the release is still a draft, it
may perform that first dispatch exactly once. Otherwise it revalidates the
original successful workflow evidence and exact image digest before adopting
the authenticated lock. Before alias creation, the release reruns or verifies
the retained live no-overwrite probe, then the HMAC journal records the complete
probe-evidence and exact-tag-to-digest mapping independently of registry state.
The code rechecks each alias immediately before creation and after mutation; a
visible conflict, rejected write, or unsettled postcondition leaves explicit
unresolved state and cannot report success. The proven server-side immutable-tag
policy supplies the atomic no-overwrite guarantee across competing registry
writers. If either GHCR
release alias is missing after successful evidence recovery, the script creates
only that missing alias from the evidenced digest. If secondary-registry staging
or either exact alias is missing, reconciliation may copy and sign that same
proven digest and create only the missing aliases; an alias at any other digest
stops the release. It is
rejected after a newer stable tag exists. For each moving channel, only the
journal's previous and target values are accepted; a third value is treated as
an external mutation and nothing further is changed. If interruption occurred
after workflow dispatch but before its run ID was checkpointed, reconciliation
searches only runs created after the signed pre-dispatch inventory and validates
the selected original run and its release evidence. If it cannot identify that
run, it stops instead of creating a same-SHA build with a different build
identity.

The workflow run ID and run attempt identify one evidence artifact and one image
build identity. A rerun receives a distinct build identity, staging tag, and
artifact name, so recovery authorization for one attempt cannot authorize bytes
from another attempt and the release does not depend on nondeterministic rebuild
equality. Reconciliation rejects an attempt change and never downloads
latest-attempt evidence under an authenticated earlier attempt. Record both
values with the release.

If publication completed but the process stopped before lock cleanup, rerun the
same exact release with the explicit reconciliation command, even if that SHA is
still current `main`. The script adopts the authenticated public-release journal,
verifies release metadata, assets, registry aliases, and static pointers, and
then returns it to an authenticated terminal tombstone. If only the terminal
tombstone survives, it is restored for this verification and returned after
success. An ordinary invocation always rejects an already-public release before
acquiring release state; only explicit reconciliation may verify it. Never clear
a release lock merely because the GitHub release is visible.

For controlled interruption drills, `RELEASE_FAULT_AFTER_STEP` terminates after
an external channel mutation but before its journal checkpoint. Valid step keys
include `ghcr_evidence`, `ghcr_tag_alias`, `ghcr_version_alias`,
`workflow_evidence_after_pending_contract`,
`workflow_evidence_after_first_anchor`, `workflow_evidence_after_both_anchors`,
`workflow_evidence_before_journal_promotion`,
`ghcr_immutability_probe_control_seed`,
`ghcr_immutability_probe_control_overwrite`, `ghcr_immutability_probe_seed`,
`ghcr_immutability_probe_conflict`, `secondary_staging`,
`secondary_immutability_probe_control_seed`,
`secondary_immutability_probe_control_overwrite`, `secondary_immutability_probe_seed`,
`secondary_immutability_probe_conflict`, `secondary_signature`, `secondary_version_alias`,
`secondary_sha_alias`, `ghcr_minor`, `ghcr_major`, `ghcr_latest`, `once_latest`,
`static_once-store-app-101`, `static_once-store-app-102`, `github_public`,
`github_latest`, `journal_anchor_1_operation`, `journal_anchor_1_revision`,
`journal_anchor_1_head`, `journal_anchor_1_workflow-evidence`,
`journal_anchor_2_operation`, `journal_anchor_2_revision`,
`journal_anchor_2_head`, `journal_anchor_2_workflow-evidence`, and `lock_cleanup`.
Exercise each key only in an approved
release drill, then prove settled-token handling and both `complete` and
`rollback` reconciliation as applicable; do not use fault injection during an
ordinary release.

### Static export hosts

Each export host must expose the moving archive and checksum through one atomic
directory pointer:

```text
campfire.zip -> campfire-current/campfire.zip
campfire.zip.sha256 -> campfire-current/campfire.zip.sha256
campfire-current -> campfire-<previous-version>
```

The release script uploads a complete immutable `campfire-VERSION` directory to
every host, verifies its checksum, and atomically replaces `campfire-current`.
Pointer replacement opens and pins the host's stable
`.campfire-current.release.lock` inode, takes an exclusive `flock`, compares the
current symlink with the authenticated expected old value again while holding
that lock, performs the atomic rename, and re-reads the result. A host without
`flock`, `/proc` descriptor identity checks, or atomic symlink rename support
fails closed; all pointer writers must honor this same remote lock.
Existing versioned archives, checksums, and files inside immutable version
directories must be regular non-symbolic-link files with the exact expected
hash; matching bytes behind a link are rejected. Accepted files and their parent
directories are explicitly synchronized before the phase is checkpointed.
Every upload uses a random, exclusively created regular staging file. Files are
published with a same-filesystem hard link that cannot replace an existing name;
accepted final files must have link count one. Version directories use random
exclusive staging, an exact two-entry inventory, and Linux
`renameat2(RENAME_NOREPLACE)`. Publication fails closed if that primitive is not
available. A raced conflicting destination or unexpected file is preserved and
aborts the release, never recursively removed or overwritten.
If a host switch fails, use explicit journal reconciliation to complete all
hosts or restore every host to its recorded previous pointer. Do not replace
these symlinks with regular files.

### Publication order

The release remains a draft while the following complete:

1. Exact GHCR architecture recovery tests, signatures, attestations, index
   child-digest verification, and durable attempt-scoped evidence upload.
2. Authenticated mutable-control writes and live same-media-type conflicts
   against every exact immutable GHCR alias, followed by the corresponding
   secondary-registry controls and aliases, GitHub, and static export
   artifacts.
3. GHCR version channels, secondary-registry `latest`, and all static host
   pointers, followed by independent digest/checksum verification.

The GitHub release is made public only after those checks. No release-event
workflow performs a second promotion.
