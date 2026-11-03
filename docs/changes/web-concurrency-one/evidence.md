# Evidence: web-concurrency-one

Local boot, development, `WEB_CONCURRENCY=1 PORT=3999`.

- YAML check prints `ok`.
- Boot log: `Puma starting in cluster mode...`, `Workers: 1`, `Worker 0 (PID: 19519) booted`. The log lines carry a `[<pid>] ` prefix, so the plan's `^\*\s+Workers: 1$` grep needs that prefix allowed.
- `ps`: master `19419 1 puma 7.2.1 (tcp://localhost:3999) [web-concurrency-one]`; `pgrep -P` count `1`; child `19519 19419 puma: cluster worker 0: 19419`.
- `/up` returned `200`.
- Action Cable: a throwaway headless-Chrome Selenium script signed in two sessions as the same user (created via the first-run screen), session B posted a message, session A showed it without a reload. `Successfully upgraded to WebSocket` appeared 4 times in the Puma log.

Checks: `bin/rubocop` 0; `bin/rails test` 259 runs, 0 failures; `db:seed:replant` (test) 0.
Not green, unrelated to this change: `bin/bundler-audit` (gem not in Gemfile), `bin/importmap audit` (9 JS advisories, mostly trix), `bin/brakeman` exit 5 (newer Brakeman 8.1.0 available), `bin/rails test:system` (ChromeDriver 156 vs Chrome 150 mismatch).
