# Rebuild request-local models from bounded, immutable database snapshots.
# The observer must still see the captured epoch after lookup and admission.
class RecordCache
  def self.fetch(key, version)
    cache = ResponseCache.instance
    return yield unless version && cache.budget.positive? && !ActiveRecord::Base.connection_pool.with_connection(&:transaction_open?)

    key = ActiveSupport::Cache.expand_cache_key([ "record-snapshot-v1", key ])
    return yield if key.bytesize > ResponseCache::MAX_KEY_BYTES

    if entry = cache.read(key, version)
      return ActiveSupport::JSON.decode(entry[:body]).map { |name, attributes| name.constantize.instantiate(attributes) }
    end

    records = yield
    if records.all? { |record| record&.persisted? && !record.changed? }
      # Raw database values retain timestamp precision and native enum binding.
      snapshot = ActiveSupport::JSON.encode(records.map { |record| [ record.class.name, record.attributes_before_type_cast ] })
      cache.write(key, version, { body: snapshot.freeze, headers: {}.freeze }.freeze)
    end
    records
  end
end
