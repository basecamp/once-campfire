# Reports how each response used Campfire's caches in its Server-Timing header:
#
#   Server-Timing: page;desc="miss", records;desc="hits=2 misses=0", fragments;desc="hits=38 misses=2"
#
# `page` is the authenticated response cache (CachedResponses): "hit" when the
# stored response was served, "miss" when this request rendered and stored it.
# `records` counts RecordCache's model snapshots and `fragments` the native
# fragment reads (message and boost partials, presentations, Jbuilder), both in
# FragmentCache's store. Browsers show the header in their network tools; a load
# generator can tell a cache hit from a render without timing either.
module CacheTimings
  extend ActiveSupport::Concern

  COUNTS = :campfire_cache_counts
  RECORD_KEY_PREFIX = "record-snapshot-v1/"

  included do
    prepend_around_action :report_cache_timings
  end

  class << self
    def count_read(event)
      if (counts = current(event))
        tally counts, event.payload[:key], event.payload[:hit]
      end
    end

    def count_read_multi(event)
      if (counts = current(event))
        hits = event.payload[:hits]
        Array(event.payload[:key]).each { |key| tally counts, key, hits.include?(key) }
      end
    end

    private
      def current(event)
        ActiveSupport::IsolatedExecutionState[COUNTS] if event.payload[:store] == FragmentCache::STORE_NAME
      end

      def tally(counts, key, hit)
        kind = key.to_s.start_with?(RECORD_KEY_PREFIX) ? :records : :fragments
        counts[kind][hit ? 0 : 1] += 1
      end
  end

  private
    def report_cache_timings
      ActiveSupport::IsolatedExecutionState[COUNTS] = { records: [ 0, 0 ], fragments: [ 0, 0 ] }
      yield
    ensure
      counts = ActiveSupport::IsolatedExecutionState[COUNTS]
      ActiveSupport::IsolatedExecutionState[COUNTS] = nil
      metrics = []
      metrics << %(page;desc="#{@response_cache_result}") if @response_cache_result
      counts&.each do |kind, (hits, misses)|
        metrics << %(#{kind};desc="hits=#{hits} misses=#{misses}") if (hits + misses).positive?
      end
      response.headers["Server-Timing"] = [ response.headers["Server-Timing"], *metrics ].compact.join(", ") if metrics.any?
    end
end
