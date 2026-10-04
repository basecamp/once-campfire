# Run through compare_message_hot_paths.rb against isolated production fixtures.
require "json"
require "digest"
require "active_support/testing/time_helpers"

include ActiveSupport::Testing::TimeHelpers
travel_to Time.utc(2026, 10, 4, 12)

# Keep framework/rendering measurements independent of Redis/network variance.
Rails.cache = ActiveSupport::Cache::MemoryStore.new
ActionView::PartialRenderer.collection_cache = Rails.cache
ApplicationController.cache_store = Rails.cache
ApplicationController.descendants.each do |controller|
  controller.cache_store = Rails.cache
  controller.allow_forgery_protection = false
end
ApplicationController.allow_forgery_protection = false

labels = JSON.parse(File.read(ENV.fetch("BENCH_LABELS")))
client = ActionDispatch::Integration::Session.new(Rails.application)
client.host! "campfire-benchmark.test"
client.post "/session", params: { email_address: labels.fetch("emails.david"), password: labels.fetch("passwords.all") }
raise "login failed" unless client.response.redirect?

paths = {
  room: "/rooms/#{labels.fetch('rooms.watercooler')}",
  messages: "/rooms/#{labels.fetch('rooms.watercooler')}/messages?before=#{labels.fetch('messages.busy_060')}",
  sidebar: Rails.application.routes.url_helpers.user_sidebar_path,
  search: "/searches?q=coffee"
}
queries = []
subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, event|
  queries << event[:sql] unless event[:cached] || event[:name] == "SCHEMA"
end
results = {}
paths.each do |name, path|
  %w[cold warm].each do |cache|
    2.times { client.get path }
    times, counts, allocations, hashes, headers = [], [], [], [], []
    Integer(ENV.fetch("BENCH_ITERATIONS", "20")).times do
      Rails.cache.clear if cache == "cold"
      queries.clear
      start_allocations = GC.stat(:total_allocated_objects)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      client.get path
      times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
      allocations << GC.stat(:total_allocated_objects) - start_allocations
      raise "#{name}: HTTP #{client.response.status}" unless client.response.status == 200
      counts << queries.length
      hashes << Digest::SHA256.hexdigest(client.response.body)
      headers << client.response.headers.slice("content-type", "etag", "cache-control", "vary")
    end
    results["#{name}_#{cache}"] = { milliseconds: times, queries: counts, allocations: allocations,
                                    body_sha256: hashes.uniq, headers: headers.uniq, body_bytes: client.response.body.bytesize }
  end
end
ActiveSupport::Notifications.unsubscribe(subscriber)

# Real Action Cable encoding/instrumentation, with adapter I/O removed. Keep fanout
# separate from network delivery capacity, which this probe does not measure.
room = Room.find(labels.fetch("rooms.watercooler"))
class BenchmarkPubsub
  attr_reader :messages
  def initialize
    @messages = []
  end
  def broadcast(stream, payload)
    @messages << [ stream, payload ]
  end
end
adapter = BenchmarkPubsub.new
ActionCable.server.instance_variable_set(:@pubsub, adapter)
message = Message.new(room: room)
recipient_ids = (1..1000).to_a
memberships = Object.new
memberships.define_singleton_method(:pluck) { |_| recipient_ids }
room.define_singleton_method(:memberships) { memberships }
fanout_times, fanout_allocations = [], []
20.times do
  adapter.messages.clear
  allocated = GC.stat(:total_allocated_objects)
  start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  message.send(:broadcast_unread_room)
  fanout_times << (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000
  fanout_allocations << GC.stat(:total_allocated_objects) - allocated
  raise "wrong fanout count" unless adapter.messages.size == recipient_ids.size
  raise "wrong payload" unless adapter.messages.all? { |_, body| JSON.parse(body) == { "roomId" => room.id } }
end
results["unread_fanout_1000"] = { milliseconds: fanout_times, allocations: fanout_allocations,
                                 payload_sha256: Digest::SHA256.hexdigest(adapter.messages.first.last) }
puts JSON.pretty_generate({ ruby: RUBY_VERSION, rails: Rails.version, iterations: ENV.fetch("BENCH_ITERATIONS", "20").to_i,
                            cache: "MemoryStore", results: results })
