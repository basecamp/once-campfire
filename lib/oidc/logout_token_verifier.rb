require "base64"
require "digest"
require "faraday"
require "json/jwt"
require "oidc/http_adapter"
require "securerandom"

module Oidc
  class LogoutTokenVerifier
    BACK_CHANNEL_LOGOUT_EVENT = "http://schemas.openid.net/event/backchannel-logout"
    CLOCK_SKEW = 1.minute.to_i
    MAXIMUM_AGE = 5.minutes.to_i
    MAXIMUM_IDENTIFIER_LENGTH = 255
    MAXIMUM_TOKEN_BYTES = 16.kilobytes
    RSA_KEY_BITS = (2048..8192).freeze
    VERIFICATION_CACHE_LIFETIME = 5.minutes
    VERIFICATION_REFRESH_INTERVAL = 5.seconds
    VERIFICATION_REFRESH_LEASE = (Oidc::HTTPAdapter::MAXIMUM_REQUEST_TIME * 2) + 5.seconds
    VERIFICATION_REFRESH_WAIT = 2.seconds
    VERIFICATION_REFRESH_POLL_INTERVAL = 0.05
    VERIFICATION_REFRESH_RESULT_LIFETIME = VERIFICATION_REFRESH_INTERVAL + VERIFICATION_REFRESH_WAIT + 1.second

    class Invalid < StandardError; end
    class Unavailable < StandardError; end
    def initialize(connection: nil, cache: Rails.cache, monotonic_clock: nil, sleeper: nil)
      @connection = connection || Faraday.new do |faraday|
        faraday.options.open_timeout = 5
        faraday.options.timeout = 10
        faraday.adapter Oidc::HTTPAdapter,
          allowed_hosts: Oidc.allowed_hosts,
          allow_private_network: Oidc.allow_private_network?
      end
      @cache = cache
      @monotonic_clock = monotonic_clock || -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) }
      @sleeper = sleeper || ->(duration) { sleep duration }
    end

    def verify(encoded_token)
      header, claims = decode_compact_token(encoded_token)
      validate_header! header
      validate_claims! claims
      verify_signature! encoded_token, header["kid"]
      claims
    rescue Invalid, Unavailable
      raise
    rescue JSON::JWT::Exception, JSON::ParserError, ArgumentError, TypeError, OpenSSL::OpenSSLError => error
      raise Invalid.new("logout token verification failed"), cause: error
    end

    private
      def decode_compact_token(encoded_token)
        unless encoded_token.is_a?(String) && encoded_token.bytesize.between?(1, MAXIMUM_TOKEN_BYTES)
          raise Invalid, "logout token is missing or too large"
        end

        segments = encoded_token.split(".", -1)
        unless segments.length == 3 && segments.all?(&:present?)
          raise Invalid, "logout token is not compact JWS"
        end

        header = parse_json_segment(segments.fetch(0))
        claims = parse_json_segment(segments.fetch(1))
        signature_segment = segments.fetch(2)
        decode_base64url(signature_segment)
        unless header.is_a?(Hash) && claims.is_a?(Hash)
          raise Invalid, "logout token header and claims must be objects"
        end

        [ header, claims ]
      end

      def parse_json_segment(segment)
        JSON.parse(decode_base64url(segment), allow_duplicate_key: false, max_nesting: 20)
      rescue JSON::ParserError => error
        raise Invalid.new("logout token contains invalid JSON"), cause: error
      end

      def decode_base64url(segment)
        unless segment.match?(/\A[A-Za-z0-9_-]+\z/)
          raise Invalid, "logout token contains invalid base64url"
        end

        decoded = Base64.urlsafe_decode64(segment)
        unless Base64.urlsafe_encode64(decoded, padding: false) == segment
          raise Invalid, "logout token contains noncanonical base64url"
        end

        decoded
      rescue ArgumentError => error
        raise Invalid.new("logout token contains invalid base64url"), cause: error
      end

      def validate_header!(header)
        unless header["alg"].is_a?(String) && header["alg"] == Oidc.signing_algorithm
          raise Invalid, "logout token algorithm is invalid"
        end
        if header.key?("kid") && !usable_identifier?(header["kid"])
          raise Invalid, "logout token key identifier is invalid"
        end
        if header.key?("typ") && !header["typ"].in?([ "JWT", "logout+jwt" ])
          raise Invalid, "logout token type is invalid"
        end
        raise Invalid, "critical JOSE extensions are unsupported" if header.key?("crit")
      end

      def validate_claims!(claims)
        now = Time.current.to_i
        unless claims["iss"].is_a?(String) && claims["iss"] == Oidc.issuer
          raise Invalid, "logout token issuer is invalid"
        end
        validate_audience! claims["aud"]
        unless claims["iat"].is_a?(Integer) &&
            claims["iat"].between?(now - MAXIMUM_AGE, now + CLOCK_SKEW)
          raise Invalid, "logout token issue time is invalid"
        end
        unless usable_identifier?(claims["jti"])
          raise Invalid, "logout token identifier is invalid"
        end
        unless claims["events"].is_a?(Hash) &&
            claims["events"][BACK_CHANNEL_LOGOUT_EVENT].is_a?(Hash)
          raise Invalid, "logout token event is invalid"
        end
        raise Invalid, "logout token cannot contain nonce" if claims.key?("nonce")

        validate_lifetime! claims, now
        validate_subject_and_session! claims
      end

      def validate_audience!(audience)
        valid = if audience.is_a?(String)
          audience == Oidc.client_id
        elsif audience.is_a?(Array)
          audience == [ Oidc.client_id ]
        else
          false
        end
        raise Invalid, "logout token audience is invalid" unless valid
      end

      def validate_lifetime!(claims, now)
        unless claims["exp"].is_a?(Integer) && claims["exp"] > now - CLOCK_SKEW
          raise Invalid, "logout token expiration is invalid"
        end
        if claims.key?("nbf") &&
            (!claims["nbf"].is_a?(Integer) || claims["nbf"] > now + CLOCK_SKEW)
          raise Invalid, "logout token not-before time is invalid"
        end
        if claims.key?("azp") &&
            (!claims["azp"].is_a?(String) || claims["azp"] != Oidc.client_id)
          raise Invalid, "logout token authorized party is invalid"
        end
      end

      def validate_subject_and_session!(claims)
        has_subject = claims.key?("sub")
        has_session = claims.key?("sid")
        unless (has_subject && usable_identifier?(claims["sub"])) ||
            (has_session && usable_identifier?(claims["sid"]))
          raise Invalid, "logout token requires a usable subject or session identifier"
        end
        if (has_subject && !usable_identifier?(claims["sub"])) ||
            (has_session && !usable_identifier?(claims["sid"]))
          raise Invalid, "logout token subject or session identifier is invalid"
        end
      end

      def usable_identifier?(value)
        value.is_a?(String) && value.present? && value.bytesize <= MAXIMUM_IDENTIFIER_LENGTH
      end

      def verify_signature!(encoded_token, kid)
        return verify_signature_without_kid!(encoded_token) unless kid

        key, cached = signing_key(kid)
        JSON::JWT.decode(encoded_token, key, [ Oidc.signing_algorithm.to_sym ])
      rescue JSON::JWS::VerificationFailed
        raise unless cached

        key = coordinated_refresh_signing_key(kid)
        JSON::JWT.decode(encoded_token, key, [ Oidc.signing_algorithm.to_sym ])
      end

      def verify_signature_without_kid!(encoded_token)
        keys, cached = verification_keys
        count = verified_signature_count(encoded_token, signing_keys_from(keys))
        return if count == 1
        raise Invalid, "logout token key is ambiguous" if count > 1

        if cached
          refreshed_keys = coordinated_refresh_verification_keys
          count = verified_signature_count(encoded_token, signing_keys_from(refreshed_keys))
          return if count == 1
          raise Invalid, "logout token key is ambiguous" if count > 1
        end

        raise Invalid, "logout token signature is invalid"
      end

      def verified_signature_count(encoded_token, keys)
        keys.count do |key|
          JSON::JWT.decode(encoded_token, key, [ Oidc.signing_algorithm.to_sym ])
          true
        rescue JSON::JWS::VerificationFailed
          false
        end
      end

      def signing_key(kid, force: false, coordinate_on_miss: true)
        keys, cached = verification_keys(force:)
        matching = matching_signing_keys(keys, kid)
        if matching.empty? && cached && !force && coordinate_on_miss
          return [ coordinated_refresh_signing_key(kid), false ]
        end
        [ signing_key_from(keys, kid), cached ]
      rescue Invalid, Unavailable
        raise
      rescue Oidc::EndpointError, Oidc::HTTPAdapter::Denied, Faraday::Error,
          JSON::ParserError, Timeout::Error, SocketError, OpenSSL::OpenSSLError => error
        raise Unavailable.new("OIDC verification material is unavailable"), cause: error
      end

      def coordinated_refresh_signing_key(kid)
        signing_key_from coordinated_refresh_verification_keys, kid
      end

      def coordinated_refresh_verification_keys
        refreshing = {
          "status" => "refreshing",
          "generation" => SecureRandom.hex(16),
          "token" => SecureRandom.hex(32)
        }
        acquired = cache_write(
          cache_key("refresh"), refreshing,
          expires_in: VERIFICATION_REFRESH_LEASE, unless_exist: true
        )

        if acquired
          refresh_verification_keys_as_leader(refreshing)
        else
          follow_verification_refresh
        end
      end

      def refresh_verification_keys_as_leader(refreshing)
        begin
          verification_keys(force: true).first.tap do |refreshed_keys|
            publish_refresh_state!(refreshing, "complete", keys: refreshed_keys)
          end
        rescue StandardError
          publish_refresh_state!(refreshing, "failed")
          raise
        end
      end

      def follow_verification_refresh
        state = cache_read(cache_key("refresh"))
        case refresh_status(state)
        when "complete"
          verification_keys_from_refresh_result(state)
        when "failed"
          raise Unavailable, "OIDC verification material refresh failed"
        when "refreshing"
          wait_for_refresh_generation(state)
        else
          raise Unavailable, "OIDC verification material refresh state is unavailable"
        end
      end

      def wait_for_refresh_generation(initial_state)
        generation = valid_refresh_generation!(initial_state)
        deadline = monotonic_now + VERIFICATION_REFRESH_WAIT.to_f

        loop do
          remaining = deadline - monotonic_now
          raise Unavailable, "OIDC verification material refresh timed out" unless remaining.positive?

          sleep_for_refresh [ VERIFICATION_REFRESH_POLL_INTERVAL, remaining ].min
          # Counters bypass RedisCacheStore's request-local read cache, so other processes observe completion.
          signal = cache_increment(
            refresh_signal_key(generation), 0,
            expires_in: VERIFICATION_REFRESH_RESULT_LIFETIME
          )
          return verification_keys_from_refresh_generation(generation) if signal.positive?
        end
      end

      def signing_key_from(keys, kid)
        matching = matching_signing_keys(keys, kid)
        raise Invalid, "logout token key is ambiguous or unavailable" unless matching.one?

        rsa_signing_key matching.sole
      end

      def signing_keys_from(keys)
        matching = matching_signing_keys(keys, nil)
        raise Invalid, "logout token key is unavailable" if matching.empty?

        matching.map { rsa_signing_key(_1) }
      end

      def rsa_signing_key(key)
        unless usable_signing_key?(key)
          raise Invalid, "logout token key is not usable for verification"
        end

        rsa = JSON::JWK.new(key).to_key
        unless rsa.is_a?(OpenSSL::PKey::RSA) && RSA_KEY_BITS.cover?(rsa.n.num_bits)
          raise Invalid, "logout token RSA key strength is invalid"
        end
        rsa
      rescue Invalid
        raise
      rescue JSON::ParserError, OpenSSL::OpenSSLError => error
        raise Unavailable.new("OIDC verification material is unavailable"), cause: error
      end

      def matching_signing_keys(keys, kid)
        if kid
          keys.select { |key| key["kid"] == kid }
        else
          keys.select { usable_signing_key?(_1) }
        end
      end

      def usable_signing_key?(key)
        key["kty"] == "RSA" && (!key.key?("use") || key["use"] == "sig") &&
          (!key.key?("alg") || key["alg"] == Oidc.signing_algorithm) &&
          (!key.key?("key_ops") ||
            (key["key_ops"].is_a?(Array) && key["key_ops"].all?(String) && key["key_ops"].include?("verify")))
      end

      def verification_keys_from_refresh_result(state)
        verification_keys_from_refresh_generation valid_refresh_generation!(state)
      end

      def verification_keys_from_refresh_generation(generation)
        result = cache_read(refresh_result_key(generation))
        case refresh_status(result)
        when "complete"
          keys = result["keys"]
          unless keys.is_a?(Array) && keys.length.between?(1, 100) && keys.all?(Hash)
            raise Unavailable, "OIDC verification material refresh result is invalid"
          end
          keys
        when "failed"
          raise Unavailable, "OIDC verification material refresh failed"
        else
          raise Unavailable, "OIDC verification material refresh result is unavailable"
        end
      end

      def publish_refresh_state!(refreshing, status, keys: nil)
        current = cache_read(cache_key("refresh"))
        unless current.is_a?(Hash) && current["status"] == "refreshing" &&
            current["token"] == refreshing.fetch("token")
          raise Unavailable, "OIDC verification material refresh ownership was lost"
        end

        generation = refreshing.fetch("generation")
        result = { "status" => status }
        result["keys"] = keys if status == "complete"
        unless cache_write(
          refresh_result_key(generation), result,
          expires_in: VERIFICATION_REFRESH_RESULT_LIFETIME
        )
          raise Unavailable, "OIDC verification material refresh result is unavailable"
        end

        state = { "status" => status, "generation" => generation }
        unless cache_write(cache_key("refresh"), state, expires_in: VERIFICATION_REFRESH_INTERVAL)
          raise Unavailable, "OIDC verification material refresh state is unavailable"
        end
        signal = cache_increment(
          refresh_signal_key(generation), 1,
          expires_in: VERIFICATION_REFRESH_RESULT_LIFETIME
        )
        unless signal.is_a?(Integer) && signal.positive?
          raise Unavailable, "OIDC verification material refresh signal is unavailable"
        end
      end

      def valid_refresh_generation!(state)
        generation = state["generation"] if state.is_a?(Hash)
        unless generation.is_a?(String) && generation.match?(/\A[0-9a-f]{32}\z/)
          raise Unavailable, "OIDC verification material refresh state is invalid"
        end
        generation
      end

      def refresh_status(state)
        state["status"] if state.is_a?(Hash)
      end

      def cache_read(key)
        @cache.read(key)
      rescue StandardError => error
        raise Unavailable.new("OIDC verification cache is unavailable"), cause: error
      end

      def cache_write(key, value, **options)
        @cache.write(key, value, **options) || false
      rescue StandardError => error
        raise Unavailable.new("OIDC verification cache is unavailable"), cause: error
      end

      def cache_increment(key, amount, **options)
        value = @cache.increment(key, amount, **options)
        return value if value.is_a?(Integer)

        raise Unavailable, "OIDC verification cache is unavailable"
      rescue Unavailable
        raise
      rescue StandardError => error
        raise Unavailable.new("OIDC verification cache is unavailable"), cause: error
      end

      def monotonic_now
        @monotonic_clock.call
      rescue StandardError => error
        raise Unavailable.new("OIDC verification refresh clock is unavailable"), cause: error
      end

      def sleep_for_refresh(duration)
        @sleeper.call duration
      rescue StandardError => error
        raise Unavailable.new("OIDC verification refresh wait failed"), cause: error
      end

      def refresh_result_key(generation)
        cache_key "refresh-result", generation
      end

      def refresh_signal_key(generation)
        cache_key "refresh-signal", generation
      end

      def verification_keys(force: false)
        metadata, discovery_cached = cached_provider_json(
          discovery_url, cache_key("discovery"), force:
        )
        unless metadata.is_a?(Hash) && metadata["issuer"] == Oidc.issuer && metadata["jwks_uri"].is_a?(String) &&
            metadata["id_token_signing_alg_values_supported"].is_a?(Array) &&
            metadata["id_token_signing_alg_values_supported"].all?(String) &&
            metadata["id_token_signing_alg_values_supported"].include?(Oidc.signing_algorithm)
          raise Unavailable, "OIDC discovery metadata is invalid"
        end

        jwks_uri = Oidc.validate_endpoint!(metadata["jwks_uri"]).to_s
        jwks, jwks_cached = cached_provider_json(
          jwks_uri, cache_key("jwks", jwks_uri), force:
        )
        keys = jwks["keys"] if jwks.is_a?(Hash)
        unless keys.is_a?(Array) && keys.length.between?(1, 100) && keys.all?(Hash)
          raise Unavailable, "OIDC JWKS is invalid"
        end

        [ keys, discovery_cached || jwks_cached ]
      end

      def cached_provider_json(url, key, force:)
        unless force
          loaded = false
          value = @cache.fetch(key, expires_in: VERIFICATION_CACHE_LIFETIME) do
            loaded = true
            provider_json(url)
          end
          return [ value, !loaded ]
        end

        value = provider_json(url)
        unless @cache.write(key, value, expires_in: VERIFICATION_CACHE_LIFETIME)
          raise Unavailable, "OIDC verification cache is unavailable"
        end
        [ value, false ]
      rescue Invalid, Unavailable
        raise
      rescue StandardError => error
        raise Unavailable.new("OIDC verification cache is unavailable"), cause: error
      end

      def cache_key(kind, discriminator = nil)
        digest = Digest::SHA256.hexdigest(discriminator.to_s) if discriminator
        [ "oidc-logout-verification", Oidc.configuration.fingerprint, kind, digest ].compact.join(":")
      end

      def provider_json(url)
        response = @connection.get(url)
        raise Unavailable, "OIDC verification material is unavailable" unless response.success?

        value = JSON.parse(response.body, allow_duplicate_key: false, max_nesting: 20)
        raise Unavailable, "OIDC response must be a JSON object" unless value.is_a?(Hash)

        value
      rescue JSON::ParserError => error
        raise Unavailable.new("OIDC verification material is invalid"), cause: error
      end

      def discovery_url
        URI(Oidc.issuer).tap do |uri|
          uri.path = File.join(uri.path, ".well-known/openid-configuration")
          uri.query = nil
          uri.fragment = nil
        end.to_s
      end
  end
end
