source "https://rubygems.org"

git_source(:github) { |repo| "https://github.com/#{repo}.git" }
git_source(:bc)     { |repo| "https://github.com/basecamp/#{repo}" }

# Rails
gem "rails", github: "rails/rails", branch: "main"

# Drivers
gem "sqlite3", "~> 2.7"
gem "redis", "~> 5.4"

# Deployment
gem "puma", "~> 6.6"

# Jobs
gem "resque", "~> 2.7.0"
gem "resque-pool", "~> 0.7.1"

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
gem "kredis"
gem "platform_agent"
gem "thruster"

# Authentication
gem "omniauth"
gem "omniauth_openid_connect"
gem "jwt"

group :development, :test do
  gem "debug"
  gem "rubocop-rails-omakase", require: false
  gem "faker", require: false
  gem "brakeman", require: false
end

group :test do
  gem "capybara"
  gem "mocha"
  gem "selenium-webdriver"
  gem "webmock", require: false
end
