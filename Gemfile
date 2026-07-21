source "https://rubygems.org"

git_source(:github) { |repo| "https://github.com/#{repo}.git" }

# Rails
gem "rails", github: "rails/rails", branch: "main"
gem "ostruct"
gem "benchmark"

# Drivers
gem "sqlite3"

# Deployment
gem "puma", "~> 7.2", ">= 7.2.1"

# Jobs, caching, WebSockets
gem "solid_queue"
gem "solid_cache"
gem "solid_cable"

# Assets
gem "propshaft", github: "rails/propshaft"
gem "importmap-rails", github: "rails/importmap-rails"

# Hotwire
gem "turbo-rails", github: "hotwired/turbo-rails"
gem "stimulus-rails"

# Media handling
gem "image_processing", ">= 1.2"

# Telemetry
gem "sentry-ruby"
gem "sentry-rails"

# Other
gem "bcrypt"
gem "web-push"
gem "rqrcode"
gem "rails_autolink"
gem "geared_pagination"
gem "jbuilder"
gem "net-http-persistent"
gem "platform_agent"
gem "thruster"

group :development, :test do
  gem "debug"
  gem "rubocop-rails-omakase", require: false
  gem "bundler-audit", require: false
  gem "faker", require: false
  gem "brakeman", require: false
end

group :test do
  gem "capybara"
  gem "mocha"
  gem "selenium-webdriver"
  gem "webmock", require: false
end
