# Rebuild request-local models from bounded, immutable database snapshots.
# The observer must still see the captured epoch after lookup and admission.
class RecordCache
  def self.fetch(key, version)
    return yield unless version && ResponseCache.instance.budget.positive? && !ActiveRecord::Base.connection_pool.active_connection?&.transaction_open?

    key = ActiveSupport::Cache.expand_cache_key([ "record-snapshot-v1", version, key ])
    return yield if key.bytesize > ResponseCache::MAX_KEY_BYTES

    if snapshot = FragmentCache.store.read(key)
      if ResponseCache.instance.version == version
        return ActiveSupport::JSON.decode(snapshot).map { |name, attributes| name.constantize.instantiate(attributes) }
      end
    end

    records = yield
    if records.all? { |record| record&.persisted? && !record.changed? } && ResponseCache.instance.version == version
      # Raw database values retain timestamp precision and native enum binding.
      snapshot = ActiveSupport::JSON.encode(records.map { |record| [ record.class.name, record.attributes_before_type_cast ] })
      FragmentCache.store.write(key, snapshot) if snapshot.bytesize <= ResponseCache::MAX_ENTRY_BYTES
    end
    records
  end
end
