require "omniauth/strategies/openid_connect"

module Oidc::RejectSwdServiceRedirect
  private
    def redirect_to(*)
      raise SWD::Exception, "OIDC discovery service redirects are unsupported"
    end
end

discovery_resource = OpenIDConnect::Discovery::Provider::Config::Resource
discovery_resource.prepend(Oidc::RejectSwdServiceRedirect) unless discovery_resource < Oidc::RejectSwdServiceRedirect

class CampfireOpenIdConnectStrategy < OmniAuth::Strategies::OpenIDConnect
  RSA_KEY_BITS = (2048..8192).freeze

  option :name, "openid_connect"

  def request_phase
    browser_token = browser_token!
    return flow_in_progress_response if Oidc::Flow.pending_for?(browser_token)

    clear_flow_state
    linking_intent = prepare_linking_intent
    initiating_session = initiating_session()
    if linking_intent && initiating_session&.id != linking_intent["session_id"]
      raise CallbackError.new({ error: :invalid_linking_intent, reason: "The initiating session is invalid" })
    end
    validate_linking_authorization! linking_intent, initiating_session if linking_intent

    super.tap do
      bind_linking_intent_to_state(linking_intent)
      Oidc::Flow.start!(
        state: session.fetch("omniauth.state"),
        nonce: session.fetch("omniauth.nonce"),
        pkce_verifier: session.fetch("omniauth.pkce.verifier"),
        browser_token:,
        initiating_session_id: initiating_session&.id,
        linking_intent: session[Oidc::LINKING_INTENT_SESSION_KEY]
      )
      session[Oidc::FLOW_STARTED_AT_SESSION_KEY] = Time.current.to_i
    end
  rescue Oidc::Flow::AlreadyInProgress
    clear_flow_state
    flow_in_progress_response
  rescue Oidc::Flow::Error, ActiveRecord::ActiveRecordError => error
    clear_flow_state
    fail! :invalid_flow, error
  rescue CallbackError => error
    clear_flow_state
    fail! error.error, error
  rescue Oidc::EndpointError, Oidc::HTTPAdapter::Denied => error
    clear_flow_state
    fail! :invalid_endpoint, error
  rescue Faraday::Error, OpenIDConnect::Exception, JSON::ParserError, Timeout::Error, SocketError => error
    clear_flow_state
    fail! :provider_unavailable, error
  end

  def callback_phase
    flow = nil
    if params.key?("nonce") || params.key?("code_verifier")
      return fail!(:invalid_callback_parameters, CallbackError.new({
        error: :invalid_callback_parameters,
        reason: "Nonce and PKCE verifier must come from the initiating session"
      }))
    end

    flow = Oidc::Flow.consume!(state: params["state"], browser_token: browser_token!)
    restore_flow_state(flow)
    super
  rescue Oidc::Flow::Error, ActiveRecord::ActiveRecordError => error
    fail! :invalid_flow, error
  rescue CallbackError => error
    fail! error.error, error
  rescue Oidc::EndpointError, Oidc::HTTPAdapter::Denied, OpenIDConnect::Exception,
      JSON::JWT::Exception, JSON::ParserError => error
    fail! :invalid_token, error
  rescue Faraday::Error, Timeout::Error, SocketError => error
    fail! :provider_unavailable, error
  ensure
    flow&.abandon!
    clear_flow_state
  end

  def other_phase
    call_app!
  end

  def decode_id_token(id_token)
    decoded = JSON::JWT.decode(id_token, :skip_verification)
    @id_token_key_id = decoded.header["kid"]
    super
  ensure
    @id_token_key_id = nil
  end

  def public_key
    validate_signing_key_strength! super, @id_token_key_id
  end

  private
    def validate_signing_key_strength!(keyset, kid)
      keys = keyset.respond_to?(:to_a) ? keyset.to_a : [ keyset ]
      keys.select! { |key| key.as_json["kid"] == kid } if kid
      keys.select! do |key|
        attributes = key.as_json
        attributes["kty"] == "RSA" &&
          (!attributes.key?("use") || attributes["use"] == "sig") &&
          (!attributes.key?("alg") || attributes["alg"] == Oidc.signing_algorithm) &&
          (!attributes.key?("key_ops") ||
            (attributes["key_ops"].is_a?(Array) && attributes["key_ops"].all?(String) &&
              attributes["key_ops"].include?("verify")))
      end
      if keys.empty? || keys.any? { |key| !RSA_KEY_BITS.cover?(key.to_key.n.num_bits) }
        raise Oidc::EndpointError, "OIDC provider RSA signing key strength is invalid"
      end

      if keyset.is_a?(JSON::JWK::Set)
        JSON::JWK::Set.new(*keys)
      elsif keyset.is_a?(Array)
        keys
      else
        keys.sole
      end
    rescue OpenSSL::OpenSSLError, NoMethodError
      raise Oidc::EndpointError, "OIDC provider signing key is invalid"
    end

    def access_token
      return @access_token if @access_token

      token_request_params = {
        scope: (options.scope if options.send_scope_to_token_endpoint),
        client_auth_method: options.client_auth_method
      }

      if options.pkce
        verifier = session.delete("omniauth.pkce.verifier")
        if verifier.to_s.empty?
          raise CallbackError.new({ error: :missing_pkce_verifier, reason: "The PKCE verifier is missing" })
        end
        token_request_params[:code_verifier] = verifier
      end

      @access_token = client.access_token!(token_request_params)
      validate_access_token! @access_token
      verify_id_token! @access_token.id_token if configured_response_type == "code"
      @access_token
    end

    def user_info
      return @user_info if @user_info

      token_claims = @verified_id_token || decode_id_token(access_token.id_token)
      response = access_token.userinfo!

      unless response.valid? && same_subject?(response.sub, token_claims.sub)
        raise CallbackError.new({ error: :invalid_user_info, reason: "UserInfo did not match the ID token subject" })
      end

      @user_info = OpenIDConnect::ResponseObject::UserInfo.new(
        response.raw_attributes.merge(token_claims.raw_attributes).with_indifferent_access
      )
    end

    def same_subject?(userinfo_subject, token_subject)
      userinfo_subject.present? && token_subject.present? && userinfo_subject == token_subject
    end

    def validate_access_token!(token)
      if token.id_token.to_s.empty?
        raise CallbackError.new({ error: :missing_id_token, reason: "The token response did not include an ID token" })
      end
    end

    def discover!
      super
      validate_discovered_endpoints!
      validate_provider_capabilities!
    end

    def validate_discovered_endpoints!
      %i[ authorization_endpoint token_endpoint userinfo_endpoint jwks_uri ].each do |endpoint|
        Oidc.validate_endpoint! client_options.public_send(endpoint)
      end
    end

    def validate_provider_capabilities!
      capabilities = config.raw.with_indifferent_access
      required_client_auth = "client_secret_#{Oidc.client_auth_method}"

      unless supports?(config.response_types_supported, "code") &&
          supports?(config.id_token_signing_alg_values_supported, Oidc.signing_algorithm) &&
          supports?(capabilities[:code_challenge_methods_supported], "S256") &&
          supports?(config.token_endpoint_auth_methods_supported || [ "client_secret_basic" ], required_client_auth)
        raise Oidc::EndpointError, "OIDC provider does not advertise the configured code, PKCE, signing, and client-auth capabilities"
      end
    end

    def supports?(values, required_value)
      values.is_a?(Array) && values.all?(String) && values.include?(required_value)
    end

    def prepare_linking_intent
      intent = session[Oidc::LINKING_INTENT_SESSION_KEY]
      if params["oidc_linking"] == "1"
        unless intent.is_a?(Hash) && intent["expires_at"].to_i > Time.current.to_i &&
            intent["state"].present? &&
            ActiveSupport::SecurityUtils.secure_compare(intent["state"], params["linking_state"].to_s)
          session.delete Oidc::LINKING_INTENT_SESSION_KEY
          raise CallbackError.new({ error: :invalid_linking_intent, reason: "The linking intent is invalid or expired" })
        end
        options.state = -> { intent["state"] }
        intent
      else
        session.delete Oidc::LINKING_INTENT_SESSION_KEY
        options.state = nil
        nil
      end
    end

    def bind_linking_intent_to_state(intent)
      return unless intent.is_a?(Hash)

      session[Oidc::LINKING_INTENT_SESSION_KEY] = intent.merge("state" => session["omniauth.state"])
    end

    def flow_in_progress_response
      [ 303, { "location" => "/oidc_flow", "content-length" => "0" }, [] ]
    end

    def browser_token!
      request.cookies[Oidc::BROWSER_COOKIE].presence ||
        raise(Oidc::Flow::Invalid, "the OIDC browser binding is missing")
    end

    def initiating_session
      return unless request.cookies.key?("session_token")

      token = ActionDispatch::Request.new(env).cookie_jar.signed[:session_token]
      return unless token

      Session.includes(:identity, :user).find_by(token:)&.then do |candidate|
        candidate if candidate.valid_for_authentication?
      end
    end

    def restore_flow_state(flow)
      session["omniauth.state"] = params["state"]
      session["omniauth.nonce"] = flow.nonce
      session["omniauth.pkce.verifier"] = flow.pkce_verifier
      env["oidc.flow"] = flow
      if flow.operation == "link"
        intent = restored_linking_intent(flow)
        session[Oidc::LINKING_INTENT_SESSION_KEY] = {
          "session_id" => flow.linking_session_id,
          "expires_at" => flow.expires_at.to_i,
          "state" => params["state"],
          "return_to" => flow.return_to,
          "authorization" => intent.fetch("authorization")
        }
      else
        session.delete Oidc::LINKING_INTENT_SESSION_KEY
      end
    end

    def validate_linking_authorization!(intent, initiating_session)
      authorization = intent.fetch("authorization", nil)
      method = authorization["method"] if authorization.is_a?(Hash)
      case method
      when "password"
        valid = initiating_session && !initiating_session.user.identities.exists?(issuer: Oidc.issuer)
      when "identity"
        subject = authorization["subject"]
        valid = initiating_session && subject.is_a?(String) &&
          initiating_session.user.identities.exists?(issuer: Oidc.issuer, subject:)
      end
      unless valid
        raise CallbackError.new({ error: :invalid_linking_intent, reason: "The linking authorization is invalid" })
      end
    end

    def restored_linking_intent(flow)
      intent = session[Oidc::LINKING_INTENT_SESSION_KEY]
      valid = intent.is_a?(Hash) && intent.fetch("session_id", 0).to_i == flow.linking_session_id &&
        intent["state"].is_a?(String) && intent["state"].present? &&
        ActiveSupport::SecurityUtils.secure_compare(intent["state"], params["state"].to_s)
      raise Oidc::Flow::Invalid, "the linking authorization is missing or invalid" unless valid

      validate_linking_authorization! intent, initiating_session
      intent
    end

    def clear_flow_state
      session.delete Oidc::FLOW_STARTED_AT_SESSION_KEY
      session.delete "omniauth.state"
      session.delete "omniauth.nonce"
      session.delete "omniauth.pkce.verifier"
    end

    def verify_id_token!(id_token)
      validate_access_token! Struct.new(:id_token).new(id_token)

      nonce = session.delete("omniauth.nonce")
      if nonce.to_s.empty?
        raise CallbackError.new({ error: :missing_nonce, reason: "The OIDC nonce is missing" })
      end

      @verified_id_token = decode_id_token(id_token)
      @verified_id_token.verify!(issuer: options.issuer, client_id: client_options.identifier, nonce:)
    rescue OpenIDConnect::Exception, JSON::JWT::Exception, JSON::ParserError => error
      raise CallbackError.new({ error: :invalid_id_token, reason: error.class.name })
    end
end
