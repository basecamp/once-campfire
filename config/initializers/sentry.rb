if Rails.env.production? && ENV["SKIP_TELEMETRY"].blank?
  Sentry.init do |config|
    config.dsn = ENV["SENTRY_DSN"]
    config.breadcrumbs_logger = [ :active_support_logger, :http_logger ]
    config.send_default_pii = false
    config.release = ENV["GIT_REVISION"]
  end
end

# sentry-rails declares its Action Cable handle_open and handle_close wrappers private,
# but Rails 8.2 calls them from outside the connection, so every /cable connection fails.
# Remove once sentry-rails ships getsentry/sentry-ruby#2972 (issue #2975).
ActiveSupport.on_load(:action_cable_connection) do
  require "sentry/rails/action_cable"
  Sentry::Rails::ActionCableExtensions::Connection.send(:public, :handle_open, :handle_close)
end
