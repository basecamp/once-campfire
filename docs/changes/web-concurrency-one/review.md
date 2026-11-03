## Round 1 — 2026-11-03T11:55:11Z — aaabfa8

- [x] Important: Acceptance criterion "full test suite and every linter stay green" is not met. Evidence records `bin/bundler-audit`, `bin/importmap audit`, `bin/brakeman` (exit 5) and `bin/rails test:system` as not green, labelled "unrelated" with no baseline run on `origin/main` to prove it. Either show they fail identically on main and get Etienne's decision (playbook rule 25), or fix them. — `docs/changes/web-concurrency-one/evidence.md:11` → resolved in round 2: baseline on main b96f69d shows the same failures; Etienne decided to ship and track them separately (no dependency or tooling change here).
- [x] Nit: Evidence says the plan's `^\*\s+Workers: 1$` grep needed a `[pid]` prefix, and the `ps` bind is `tcp://localhost:3999`, not the planned `tcp://0.0.0.0:3999`. Proof text and evidence differ; harmless but note it. — `docs/changes/web-concurrency-one/evidence.md:6` → resolved in round 2: evidence.md now explains the localhost bind.

Scope: diff in `config/deploy.yml` is the single line `WEB_CONCURRENCY: "1"` under `env.clear`; no other code touched. Criteria for YAML, one worker via `ps`, `/up` 200 and Action Cable are each supported by the evidence (manual/Selenium, no test in the diff, as plan Proof specifies). Bugs, Security, Design: nothing found.

## Round 2 — 2026-11-03T12:30:00Z — 59b0ea9

- Nothing found. Diff against origin/main is the one line `WEB_CONCURRENCY: "1"` in `config/deploy.yml` plus change-folder docs. Baseline claims reproduced on main: `bin/importmap audit` reports 9 vulnerabilities (7 moderate, 2 low); `bin/brakeman` prints only the newer-version notice; `bin/bundler-audit` fails with a load error. Round 1 findings are closed above.
