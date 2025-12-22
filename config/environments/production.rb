require "active_support/core_ext/integer/time"
require "active_support/core_ext/numeric/bytes"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled and caching is turned on.
  config.consider_all_requests_local       = false
  config.action_controller.perform_caching = true

  # Cache digest stamped assets for far-future expiry.
  # Short cache for others: robots.txt, sitemap.xml, 404.html, etc.
  config.public_file_server.headers = {
    "cache-control" => lambda do |path, _|
      if path.start_with?("/assets/")
        # Files in /assets/ are expected to be fully immutable.
        # If the content change the URL too.
        "public, immutable, max-age=#{1.year.to_i}"
      else
        # For anything else we cache for 1 minute.
        "public, max-age=#{1.minute.to_i}, stale-while-revalidate=#{5.minutes.to_i}"
      end
    end
  }

  # Ensures that a master key has been made available in either ENV["RAILS_MASTER_KEY"]
  # or in config/master.key. This key is used to decrypt credentials (and other encrypted files).
  # config.require_master_key = true

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :local

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  # config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  # config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT by default
  config.logger = ActiveSupport::Logger.new(STDOUT)
    .tap  { |logger| logger.formatter = ::Logger::Formatter.new }
    .then { |logger| ActiveSupport::TaggedLogging.new(logger) }

  # Prepend all log lines with the following tags.
  config.log_tags = [ :request_id ]

  # Info include generic and useful information about system operation, but avoids logging too much
  # information to avoid inadvertent exposure of personally identifiable information (PII). Use "debug"
  # for everything.
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Cache in memory for now
  config.cache_store = :redis_cache_store

  # Assets are cacheable
  config.public_file_server.headers = {
    "Cache-Control" => "public, max-age=#{30.days.to_i}"
  }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Always be SSL'ing (unless told not to)
  config.assume_ssl = ENV["DISABLE_SSL"].blank?
  config.force_ssl  = ENV["DISABLE_SSL"].blank?

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  config.active_job.queue_adapter = :resque

  # SMTP mailer setup
  config.feature_enable_smtp = ENV.fetch("SMTP_ENABLED", false)
  config.action_mailer.delivery_method = :smtp
  config.action_mailer.smtp_settings = {
    address:         ENV.fetch("SMTP_ADDRESS", nil),
    port:            ENV.fetch("SMTP_PORT", nil),
    domain:          ENV.fetch("SMTP_DOMAIN", nil),
    user_name:       ENV.fetch("SMTP_USER_NAME", nil),
    password:        ENV.fetch("SMTP_PASSWORD", nil),
    authentication:  "plain",
    enable_starttls: true,
    open_timeout:    5,
    read_timeout:    5
  }
end
