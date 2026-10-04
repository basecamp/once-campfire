# Ruby performance pass — 2026-10-04

Baseline: `90b3300`. Candidate: the local `optimize/message-rendering` branch.
Ruby 3.4.10 / Rails 8.2.0.alpha; identical locked gems, seed data, assets and image.

## Changes

- Fix the discarded rich-text preload and share a presentation preload graph across message views.
- Let Rails preload only collection-cache misses through a small Array-compatible page wrapper. Keep existing pagination, timestamp-tie ordering and validators.
- Use collection caching for search results and skip the absent-message lookup on ordinary room visits.
- Partition the sidebar memberships already loaded instead of querying them a second time.
- Encode unread-room JSON once per fanout; retain the same per-member streams and payload bytes.

## Production HTTP

Fresh isolated Puma/Redis containers, one worker/five threads, server CPUs 8–11 and
load generator CPUs 12–15. Two runs per variant in AB/BA order. Keep-alive HTTP,
no gzip, Thruster or TLS. Every measured response was HTTP 200; no transport errors.
These are backend request measurements, not the earlier full deployment comparison.

| Workload | Clients | Seconds/run | Before req/s | After req/s | Change |
|---|---:|---:|---:|---:|---:|
| room | 1 | 3 | 101.9 | 126.0 | +23.7% |
| room | 16 | 3 | 79.3 | 91.4 | +15.3% |
| messages | 1 | 3 | 215.8 | 257.1 | +19.1% |
| messages | 16 | 3 | 223.2 | 265.1 | +18.8% |
| sidebar | 1 | 3 | 212.8 | 252.1 | +18.4% |
| sidebar | 16 | 10 | 152.0 | 170.2 | +12.0% |
| search | 1 | 3 | 199.4 | 210.9 | +5.8% |
| search | 16 | 10 | 140.4 | 153.1 | +9.0% |

Short three-second sidebar/search contention samples showed regressions. Repeating
those cases with a three-second warmup and ten-second measurements reversed that
result; both variants vary with process/JIT/GC scheduling. The raw short and longer
runs are retained. Treat these percentages as local observations, not capacity promises.

## Request and serialization probes

Two production processes per variant in AB/BA order, 20 requests per state/run.
Templates/database are warmed. Cold clears fragment/collection caches; warm retains them.
MemoryStore, frozen clock and fixture-only CSRF disabling isolate the rendering work.
The unread probe uses real Cable encoding/instrumentation with adapter I/O removed.

| Workload | Before ms | After ms | SQL before → after | Allocations before → after |
|---|---:|---:|---:|---:|
| room_cold | 115.46 | 115.00 | 95 → 57 | 224129 → 215979 |
| room_warm | 9.58 | 8.25 | 13 → 7 | 16567 → 12446 |
| messages_cold | 103.81 | 78.85 | 128 → 52 | 223494 → 208427 |
| messages_warm | 3.73 | 3.77 | 8 → 6 | 6770 → 6051 |
| sidebar_cold | 7.35 | 6.09 | 12 → 11 | 13007 → 12249 |
| sidebar_warm | 4.70 | 4.12 | 9 → 8 | 10464 → 9693 |
| search_cold | 32.37 | 29.34 | 49 → 27 | 81832 → 76795 |
| search_warm | 4.33 | 4.33 | 7 → 7 | 9402 → 8736 |
| unread_fanout_1000 | 2.32 | 1.86 | — | 17000 → 14003 |

Bodies, selected headers (including ETags) and unread payloads match exactly across
all baseline/candidate probe requests. Warm message/search probe timings are essentially
unchanged; cold room rendering is also unchanged despite fewer queries. No schema,
storage, protocol or authentication changes were made.

## Validation and reproduction

`bundle exec rails test`: **411 runs, 1,381 assertions, zero failures/errors, two skips**.
The skips are existing libvips loader checks unsupported by the image. Browser/system
tests were not run. RuboCop passes for all changed Ruby files and the Ruby probe.
New tests cover batched presentation reads, cache-miss-only loading, timestamp ties,
warm cached requests without presentation SQL and edit invalidation.

Create a frozen source snapshot, provide an isolated seed (`db/`, `storage/`,
`labels.json`) and the existing load generator, then:

```sh
python3 bench/compare_message_hot_paths.py --baseline PATH --baseline-ref 90b3300 --seed SEED --rounds 2 --output OUTPUT
python3 bench/compare_http.py --baseline PATH --seed SEED --loadgen LOADGEN --output OUTPUT
python3 bench/compare_http.py --baseline PATH --seed SEED --loadgen LOADGEN --paths sidebar,search --concurrencies 16 --duration 10 --output OUTPUT
```

The probes use the cached `campfire-reference:app` image; override `--image` for a
matching locally built image. Run the request probe first to extract the shared
compiled assets. The fixture directories are disposable and separate from the seed.
Raw measurements and metadata are in `balanced/`, `http/`, `http-contention/`
and `http-summary.json`. Test output is in `tests.txt`.
