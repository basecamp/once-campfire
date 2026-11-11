# frozen_string_literal: true

# Backlit owns this fork's semver (VERSION). Deploy can still override with
# APP_VERSION (release tags) or fall back to GIT_REVISION for local builds.
version_file = Rails.root.join("VERSION")
file_version = version_file.exist? ? version_file.read.strip.presence : nil

Rails.application.config.app_version =
  ENV["APP_VERSION"].presence || file_version || ENV["GIT_REVISION"].presence || "0"
Rails.application.config.git_revision = ENV["GIT_REVISION"]
