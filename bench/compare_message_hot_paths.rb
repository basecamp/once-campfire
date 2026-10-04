#!/usr/bin/env ruby
# Compare frozen Rails sources with isolated fixtures and an existing Ruby image.
require "digest"
require_relative "support"

include BenchmarkSupport
options = parse_options("Compare rendering queries, allocations, timing and response parity.",
  baseline_ref: nil, rounds: 4, output: File.join(WORK, "results/requests"))
work = File.join(WORK, "runtime")
FileUtils.mkdir_p([ File.join(work, "tmp"), File.join(work, "log") ])
assets = prepare_assets(options[:image])
runs = { "before" => [], "after" => [] }
order = []
options[:rounds].times do |iteration|
  sides = iteration.even? ? %w[before after] : %w[after before]
  order << sides
  sides.each do |side|
    storage = File.join(work, "storage")
    prepare_storage(options[:seed], storage)
    source = side == "before" ? options[:baseline] : ROOT
    command = [ "docker", "run", "--rm", "--entrypoint", "", "--cpuset-cpus", options[:cpus] ]
    command.concat mounts(source => "/rails", storage => "/rails/storage", File.join(work, "tmp") => "/rails/tmp",
      File.join(work, "log") => "/rails/log", assets => "/rails/public/assets", File.join(ROOT, "bench") => "/bench",
      File.join(options[:seed], "labels.json") => "/bench-labels.json")
    command.concat environment(RAILS_ENV: "production", SECRET_KEY_BASE: "isolated-benchmark-fixture-key", DISABLE_SSL: true,
      SKIP_TELEMETRY: true, RAILS_LOG_LEVEL: "fatal", BENCH_LABELS: "/bench-labels.json")
    command.concat [ options[:image], "bundle", "exec", "ruby", "-r", "/rails/config/environment.rb", "/bench/message_hot_paths.rb" ]
    data = JSON.parse(run(*command))
    runs[side] << data
    write_json(File.join(options[:output], "#{side}-#{iteration + 1}.json"), data)
    puts "#{iteration + 1}/#{options[:rounds]}: #{side}"
  end
end

summary = {}
runs["before"].first.fetch("results").each_key do |name|
  values = runs.transform_values { |rows| rows.map { |row| row.fetch("results").fetch(name) } }
  %w[body_sha256 headers payload_sha256].each do |field|
    expected = values["before"].first[field]
    raise "#{name}: #{field} differs; no winning summary written" unless values.values.flatten.all? { |row| row[field] == expected }
  end
  summary[name] = values.transform_values do |rows|
    fields = %w[milliseconds allocations queries].select { |field| rows.first.key?(field) }
    fields.to_h { |field| [ field, median(rows.map { |row| median(row.fetch(field)) }) ] }
      .merge("round_medians_ms" => rows.map { |row| median(row.fetch("milliseconds")) })
  end
  summary[name]["speedup"] = summary[name]["before"]["milliseconds"] / summary[name]["after"]["milliseconds"]
end
metadata = {
  baseline_sha: options[:baseline_ref], candidate_head: run("git", "-C", ROOT, "rev-parse", "HEAD").strip,
  candidate_app_diff_sha256: Digest::SHA256.hexdigest(run("git", "-C", ROOT, "diff", "--", "app")),
  platform: RUBY_PLATFORM, cpus: options[:cpus], image: options[:image],
  image_id: run("docker", "image", "inspect", "-f", "{{.Id}}", options[:image]).strip,
  body_and_selected_header_parity: "exact across all measured baseline/candidate requests",
  order: order, ruby: runs["before"].first.fetch("ruby"), rails: runs["before"].first.fetch("rails"),
  limits: "In-process Rails requests, MemoryStore, frozen clock and fixture-controller CSRF disabled. Fanout excludes adapter I/O. Not network throughput or connection capacity."
}
write_json(File.join(options[:output], "summary.json"), metadata: metadata, results: summary)
summary.each do |name, value|
  puts "%s: %.2f -> %.2f ms (%.2fx)" % [ name, value["before"]["milliseconds"], value["after"]["milliseconds"], value["speedup"] ]
end
