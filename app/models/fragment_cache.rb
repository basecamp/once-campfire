# Native view caches share one byte budget across every database generation.
class FragmentCache
  STORE = ActiveSupport::Cache::MemoryStore.new(size: 64.megabytes)
  private_constant :STORE

  def self.store
    STORE
  end
end
