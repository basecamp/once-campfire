#!/usr/bin/env ruby
# Compare warm production Puma/Redis requests using isolated seeded containers.
require "socket"
require_relative "support"
require_relative "http_client"

include BenchmarkSupport
options = parse_options("Compare HTTP throughput with Ruby keep-alive clients; every response must be HTTP 200.",
  duration: 3.0, paths: "room,messages,sidebar,search", concurrencies: "1,16", client_cpus: "12-15",
  output: File.join(WORK, "results/http"))
labels = JSON.parse(File.read(File.join(options[:seed], "labels.json")))
paths = {
  "room" => "/rooms/#{labels.fetch('rooms.watercooler')}",
  "messages" => "/rooms/#{labels.fetch('rooms.watercooler')}/messages?before=#{labels.fetch('messages.busy_060')}",
  "sidebar" => "/users/me/sidebar", "search" => "/searches?q=coffee"
}.slice(*options[:paths].split(","))
abort "--paths must select room,messages,sidebar,search" unless paths.size == options[:paths].split(",").size && !paths.empty?
concurrencies = options[:concurrencies].split(",").map { |value| Integer(value) }
abort "--duration and --concurrencies must be positive" unless options[:duration].positive? && !concurrencies.empty? && concurrencies.all?(&:positive?)
run("taskset", "-pc", options[:client_cpus], Process.pid.to_s)
work = File.join(WORK, "http")
assets = prepare_assets(options[:image])
network = "cf-ruby-bench-#{Process.pid}"
redis = "#{network}-redis"
app = "#{network}-app"

begin
  run("docker", "network", "create", network)
  run("docker", "run", "-d", "--name", redis, "--network", network, "redis:7-alpine")
  options[:rounds].times do |iteration|
    sides = iteration.even? ? %w[before after] : %w[after before]
    sides.each do |side|
      remove_container(app)
      data = File.join(work, "data")
      prepare_storage(options[:seed], File.join(data, "storage"))
      FileUtils.mkdir_p([ File.join(data, "tmp/pids"), File.join(data, "log") ])
      run("docker", "exec", redis, "redis-cli", "FLUSHALL")
      port = TCPServer.open("127.0.0.1", 0) { |socket| socket.addr[1] }
      client = BenchmarkHTTPClient.new("http://127.0.0.1:#{port}")
      source = side == "before" ? options[:baseline] : ROOT
      command = [ "docker", "run", "-d", "--name", app, "--entrypoint", "", "--network", network,
        "--cpuset-cpus", options[:cpus], "-p", "127.0.0.1:#{port}:3000" ]
      command.concat mounts(source => "/rails", File.join(data, "storage") => "/rails/storage",
        File.join(data, "tmp") => "/rails/tmp", File.join(data, "log") => "/rails/log", assets => "/rails/public/assets")
      command.concat environment(RAILS_ENV: "production", SECRET_KEY_BASE: "isolated-benchmark-fixture-key", DISABLE_SSL: true,
        SKIP_TELEMETRY: true, RAILS_LOG_LEVEL: "fatal", WEB_CONCURRENCY: 1, JOB_CONCURRENCY: 1, RAILS_MAX_THREADS: 5,
        REDIS_URL: "redis://#{redis}:6379/0")
      command.concat [ options[:image], "bundle", "exec", "puma", "-C", "config/puma.rb" ]
      run(*command)
      deadline = clock + 45
      until client.ready?
        if clock > deadline
          File.write(File.join(work, "server.log"), run("docker", "logs", app))
          raise "server did not become ready; see #{work}/server.log"
        end
        sleep 0.1
      end
      cookie = client.login(labels)
      results = {}
      paths.each do |name, path|
        client.measure(path, cookie, concurrency: 1, duration: 3)
        concurrencies.each do |concurrency|
          results["#{name}_#{concurrency}"] = client.measure(path, cookie, concurrency: concurrency, duration: options[:duration])
        end
      end
      write_json(File.join(options[:output], "#{side}-#{iteration + 1}.json"), results)
      puts "#{iteration + 1}/#{options[:rounds]}: #{side}"
    end
  end
ensure
  remove_container(app)
  remove_container(redis)
  Open3.capture3("docker", "network", "rm", network)
end
