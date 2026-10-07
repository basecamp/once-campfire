require "jbuilder/jbuilder_template"

# Jbuilder 2.14.1 uses Rails.cache directly; use the same bounded store as ERB
# while retaining its native keys and controller instrumentation.
module BoundedJbuilderFragments
  private
    def _read_fragment_cache(key, options = nil)
      @context.controller.instrument_fragment_cache :read_fragment, key do
        @context.controller.cache_store.read(key, options)
      end
    end

    def _write_fragment_cache(key, options = nil)
      @context.controller.instrument_fragment_cache :write_fragment, key do
        yield.tap { |value| @context.controller.cache_store.write(key, value, options) }
      end
    end
end

JbuilderTemplate.prepend(BoundedJbuilderFragments)

Rails.application.config.to_prepare do
  ActionView::PartialRenderer.collection_cache = FragmentCache.store
end
