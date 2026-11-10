key_generator = Rails.application.key_generator
credentials = Rails.application.credentials
configured_keys = credentials.respond_to?(:dig) ? credentials.dig(:active_record_encryption) : nil

ActiveRecord::Encryption.configure(
  primary_key: ENV["ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY"] ||
    configured_keys&.dig(:primary_key) ||
    key_generator.generate_key("active_record_encryption.primary_key", 32),
  deterministic_key: ENV["ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY"] ||
    configured_keys&.dig(:deterministic_key) ||
    key_generator.generate_key("active_record_encryption.deterministic_key", 32),
  key_derivation_salt: ENV["ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT"] ||
    configured_keys&.dig(:key_derivation_salt) ||
    key_generator.generate_key("active_record_encryption.key_derivation_salt", 32)
)
