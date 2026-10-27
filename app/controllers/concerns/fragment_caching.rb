module FragmentCaching
  extend ActiveSupport::Concern

  included do
    before_action { @rendering_request = true }
    fragment_cache_key { [ Rails.configuration.x.presentation_cache_version, request.base_url, request.script_name, I18n.locale ] }
  end

  # Detached broadcasts and uncommitted renders must not populate shared caches.
  def perform_caching
    super && @rendering_request && !ActiveRecord::Base.connection_pool.with_connection(&:transaction_open?)
  end
end
