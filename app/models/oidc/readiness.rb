require "securerandom"

class Oidc::Readiness
  PROBE_LIFETIME = 1.minute

  class << self
    def ready?(store: Rails.cache)
      token = SecureRandom.hex(16)
      value_key = "oidc-readiness:value:#{token}"
      counter_key = "oidc-readiness:counter:#{token}"

      return false unless store.write(value_key, token, expires_in: PROBE_LIFETIME, unless_exist: true)
      return false unless store.read(value_key) == token
      return false unless store.increment(counter_key, 1, expires_in: PROBE_LIFETIME) == 1
      return false unless store.increment(counter_key, 1, expires_in: PROBE_LIFETIME) == 2
      return false unless store.delete(value_key)
      return false unless store.delete(counter_key)

      value_key = counter_key = nil
      true
    rescue StandardError
      false
    ensure
      begin
        store.delete(value_key) if value_key
        store.delete(counter_key) if counter_key
      rescue StandardError
        false
      end
    end
  end
end
