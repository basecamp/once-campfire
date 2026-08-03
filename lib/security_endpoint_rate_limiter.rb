require "digest"

class SecurityEndpointRateLimiter
  class Unavailable < StandardError; end

  class << self
    def exceeded?(endpoint:, remote_ip:, limit:, window:, store: Rails.cache)
      client = Digest::SHA256.hexdigest(remote_ip.to_s).first(24)
      count = store.increment(
        [ "security-endpoint", endpoint, client ].join(":"), 1, expires_in: window
      )
      return count > limit if count.is_a?(Integer)

      raise Unavailable, "rate limit storage is unavailable"
    rescue Unavailable
      raise
    rescue StandardError => error
      raise Unavailable.new("rate limit storage is unavailable"), cause: error
    end
  end
end
