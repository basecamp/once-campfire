# Count fragment cache reads for the request in progress (see CacheTimings).
ActiveSupport::Notifications.subscribe("cache_read.active_support") { |event| CacheTimings.count_read(event) }
ActiveSupport::Notifications.subscribe("cache_read_multi.active_support") { |event| CacheTimings.count_read_multi(event) }
