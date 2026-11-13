Rails.application.config.app_version = ENV["APP_VERSION"].presence || ENV["GIT_REVISION"].presence || "0"
Rails.application.config.git_revision = ENV["GIT_REVISION"]

# Official builds share fragments across workers. Unversioned builds start cold
# on boot rather than reuse HTML from a different helper/asset/signing deployment.
Rails.application.config.x.presentation_cache_version = [
  ENV["GIT_REVISION"].presence || SecureRandom.hex(16),
  Digest::SHA256.hexdigest(Rails.application.secret_key_base)
]
