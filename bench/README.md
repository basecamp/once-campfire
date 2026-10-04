# Message benchmarks

The drivers use Ruby's standard library and Docker; no separate load generator is required.
Provide a frozen baseline source directory, an isolated seed containing `db/`, `storage/`
and `labels.json`, and a matching application image with compiled assets.

```sh
ruby bench/compare_message_hot_paths.rb --baseline PATH --baseline-ref SHA --seed SEED
ruby bench/compare_http.rb --baseline PATH --seed SEED
ruby bench/compare_http.rb --baseline PATH --seed SEED --paths sidebar,search --concurrencies 16 --duration 10
```

Both drivers alternate before/after order and reset fixture storage for each run.
Results default to ignored `tmp/rails-optimization/results/`; override with `--output PATH`.
Use `--image` to override `campfire-reference:app`, and `--cpus` to override server CPUs
`8-11`. HTTP clients use CPUs `12-15` by default (`--client-cpus`). `--help` lists options.

The rendering probe checks exact response bodies, selected headers and unread payloads,
and records timing, queries and allocations with MemoryStore, frozen time and fixture-only
CSRF disabling. Unread fanout excludes adapter I/O.

The HTTP driver uses production Puma/Redis with one worker and five threads. Ruby threads
each maintain a keep-alive connection, request uncompressed responses, and consume the
whole body. Login uses normal CSRF protection; all warmup and measured responses must be
HTTP 200 without transport errors. Measurements exclude Thruster, TLS and gzip. Client
CPU, JIT warmup and GC can affect throughput; repeat runs and check client saturation.
