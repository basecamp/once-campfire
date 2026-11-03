# Intent: Run one Puma worker in production

Author: Etienne van Delden de la Haije. Status: accepted (2026-10-26). Type: chore.
Delivery: autonomous
Codex review: no

## Problem

Campfire uses too much memory on the Kamal host CT104, which has 3 cores and 12 GB and runs about 12 apps. Campfire runs 6 Ruby processes plus Redis, 592 MB in total. `WEB_CONCURRENCY` is unset, so `config/puma.rb` starts ceil(3 x 0.666) = 2 Puma workers. Each worker holds 116 to 126 MB of private memory. The app has 2 to 5 users, so the second worker adds no useful throughput.

## Proposed outcome

Production runs one Puma worker. The app frees about 120 MB on CT104. Pages, `/up` and Action Cable behave as before.

## Affected users and systems

- CT104 and the other apps that share its memory.
- The 2 to 5 Campfire users: no visible change expected.
- `config/deploy.yml`, `env.clear`.

## Constraints

- Etienne deploys. No kamal command runs in this change.
- Keep `preload_app!` in `config/puma.rb` (commit 447bcad).
- No application code change: the fork tracks upstream `basecamp/once-campfire`.
- `config/resque-pool.yml` stays unchanged (2 Resque workers, upstream code).
- `config/puma.rb` sets `JOB_CONCURRENCY` from the computed worker count (2), not from `WEB_CONCURRENCY`. Nothing else in the repository reads it, so this change leaves it as is.
- Approved permission: editing `config/deploy.yml` (playbook rule 13). No other permission is needed.
- The untracked and modified files in the main checkout (`config/credentials.yml.enc`, `.kamal/`, `config/deploy.yml.bk`, `erd.pdf`, `bin/setup`) stay out of the commit. No secret is read.

## In scope

- Add `WEB_CONCURRENCY: 1` to `env.clear` in `config/deploy.yml`.
- Verify locally and record the evidence.

## Out of scope

- `WEB_CONCURRENCY=0` (single mode). Untested for Campfire. Recorded as a possible follow-up.
- Changes to `config/puma.rb`, `config/resque-pool.yml` or any application code.
- Deploying.

## Acceptance criteria

- `config/deploy.yml` sets `WEB_CONCURRENCY: "1"` under `env.clear`, and the file stays valid YAML.
- Booting Puma locally with `WEB_CONCURRENCY=1` shows, with `ps`, one Puma master and exactly one worker.
- `/up` returns 200 on that boot.
- A chat page on that boot still connects to Action Cable.
- The full test suite and every linter stay green.

## Decisions

- `WEB_CONCURRENCY` is 1, not 0 — keeps the cluster mode that production runs today. Single mode is untested for Campfire.
- Delivery is autonomous, with no Codex review — no reason given.

## Open questions

None.
