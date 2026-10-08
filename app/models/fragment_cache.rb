# Native view caches share one byte budget across every database generation.
class FragmentCache
  # Only callers that fingerprint every rendered dependency may omit the epoch.
  ContentKey = Data.define(:digest) do
    def cache_key
      digest
    end
  end

  STORE = ActiveSupport::Cache::MemoryStore.new(size: 64.megabytes)
  private_constant :STORE

  def self.store
    STORE
  end

  def self.transaction_open?
    ActiveRecord::Base.connection_pool.with_connection(&:transaction_open?)
  end
end
