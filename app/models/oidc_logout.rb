require "json"
require "net/http"
require "uri"

class OidcLogout
  DISCOVERY_DOCUMENT = ".well-known/openid-configuration".freeze
  REQUEST_TIMEOUT = 2.seconds

  class << self
    def logout_url_for(strategy:, post_logout_redirect_uri:, id_token_hint: nil, env: ENV)
      provider = OidcConfiguration.provider_for_strategy(strategy, env:)
      return if provider.blank?

      end_session_endpoint = provider.fetch(:end_session_endpoint).presence || discover_end_session_endpoint(provider.fetch(:issuer))
      return if end_session_endpoint.blank?

      build_logout_url(
        end_session_endpoint: end_session_endpoint,
        client_id: provider.fetch(:client_id),
        post_logout_redirect_uri: post_logout_redirect_uri,
        id_token_hint: id_token_hint
      )
    rescue ArgumentError => e
      Rails.logger.warn("OIDC logout skipped for strategy #{strategy.inspect}: #{e.message}")
      nil
    end

    private
      def discover_end_session_endpoint(issuer)
        metadata = provider_metadata(issuer)
        metadata["end_session_endpoint"].presence
      end

      def provider_metadata(issuer)
        uri = discovery_uri(issuer)
        response = http_get(uri)
        return {} unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      rescue JSON::ParserError, URI::InvalidURIError, SocketError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout => e
        Rails.logger.warn("Failed to load OIDC metadata for issuer #{issuer.inspect}: #{e.class}: #{e.message}")
        {}
      end

      def discovery_uri(issuer)
        uri = URI.parse(issuer)
        issuer_path = uri.path.to_s.delete_suffix("/")
        uri.path = "#{issuer_path}/#{DISCOVERY_DOCUMENT}"
        uri.query = nil
        uri.fragment = nil
        uri
      end

      def http_get(uri)
        Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https", open_timeout: REQUEST_TIMEOUT, read_timeout: REQUEST_TIMEOUT) do |http|
          http.get(uri.request_uri)
        end
      end

      def build_logout_url(end_session_endpoint:, client_id:, post_logout_redirect_uri:, id_token_hint:)
        uri = URI.parse(end_session_endpoint)
        params = Rack::Utils.parse_nested_query(uri.query.to_s)
        params["client_id"] ||= client_id
        params["post_logout_redirect_uri"] ||= post_logout_redirect_uri
        params["id_token_hint"] ||= id_token_hint if id_token_hint.present?
        uri.query = params.to_query
        uri.to_s
      rescue URI::InvalidURIError => e
        Rails.logger.warn("Invalid OIDC end-session endpoint #{end_session_endpoint.inspect}: #{e.message}")
        nil
      end
  end
end
