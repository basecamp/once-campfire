class Oidc::BackChannelLogoutsController < ActionController::API
  def create
    response.set_header "Cache-Control", "no-store"
    return head :not_found unless Oidc.enabled?

    Oidc::LogoutToken.consume! validated_logout_token
    head :ok
  rescue Oidc::LogoutTokenVerifier::Invalid, Oidc::LogoutToken::Replay,
      ActionDispatch::Http::Parameters::ParseError, Rack::QueryParser::InvalidParameterError => error
    log_failure("invalid", error)
    head :bad_request
  rescue Oidc::LogoutTokenVerifier::Unavailable, ActiveRecord::ActiveRecordError => error
    log_failure("unavailable", error)
    head :service_unavailable
  end

  private
    def validated_logout_token
      unless request.media_type == "application/x-www-form-urlencoded" &&
          request.query_parameters.empty?
        raise Oidc::LogoutTokenVerifier::Invalid, "logout request is malformed"
      end

      raw_body = request.get_header(SecurityEndpointBodyLimiter::RAW_BODY_KEY) || request.raw_post.to_s
      token = Rack::Utils.parse_query(raw_body)["logout_token"]
      unless token.is_a?(String) && token.bytesize.between?(1, Oidc::LogoutTokenVerifier::MAXIMUM_TOKEN_BYTES)
        raise Oidc::LogoutTokenVerifier::Invalid, "logout token is missing, duplicated, or unusable"
      end
      token
    end

    def log_failure(reason, error)
      Rails.logger.warn(
        "OIDC back-channel logout rejected request_id=#{request.request_id} " \
          "reason=#{reason} error=#{error.class.name}"
      )
    end
end
