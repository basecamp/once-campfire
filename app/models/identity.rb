class Identity < ApplicationRecord
  class AuthenticationError < StandardError; end

  CLOCK_SKEW = 1.minute.to_i
  MAXIMUM_IDENTIFIER_LENGTH = 255
  SCIM_ID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/

  belongs_to :user
  has_many :sessions, dependent: :delete_all

  before_validation :set_provider_fingerprint, :set_scim_id, on: :create

  validates :issuer, :subject, :provider_fingerprint, presence: true, length: { maximum: MAXIMUM_IDENTIFIER_LENGTH }
  validates :scim_id, presence: true, uniqueness: true, format: { with: SCIM_ID_PATTERN }
  validates :subject, uniqueness: { scope: :issuer }
  validates :user_id, uniqueness: { scope: :issuer }
  validate :immutable_identity_binding, :permanent_provider_revocation, on: :update

  class << self
    def authenticate(auth, linking_user: nil, linking_authorization: nil)
      claims = validated_claims(auth)
      issuer = claims.fetch("iss")
      subject = claims.fetch("sub")
      validate_linking_authorization! linking_user, linking_authorization, issuer, subject if linking_user

      if identity = find_by(issuer:, subject:)
        return authenticate_existing! identity, claims, linking_user
      end

      link_identity!(issuer:, subject:, claims:, linking_user:)
    rescue ActiveRecord::RecordNotUnique
      authenticate_existing! find_by(issuer:, subject:), claims, linking_user
    rescue KeyError, TypeError, ArgumentError
      raise AuthenticationError, "invalid_claims"
    end

    def provider_session_id(auth)
      provider_session_attributes(auth).fetch(:oidc_session_id)
    end

    def provider_session_attributes(auth)
      claims = raw_claims(auth)
      issued_at = claims["iat"]
      unless issued_at.is_a?(Integer) && issued_at.positive?
        raise AuthenticationError, "invalid_token_lifetime"
      end

      { oidc_session_id: validated_provider_session_id(claims), oidc_issued_at: issued_at }
    end

    private
      def validated_claims(auth)
        raise AuthenticationError, "invalid_provider" unless auth&.[](:provider).to_s == "openid_connect"
        raise AuthenticationError, "missing_id_token" if auth.dig(:credentials, :id_token).to_s.empty?

        claims = raw_claims(auth)

        subject = claims["sub"]
        authorized_party = claims["azp"]
        now = Time.current.to_i

        raise AuthenticationError, "invalid_issuer" unless claims["iss"].is_a?(String) && claims["iss"] == Oidc.issuer
        unless subject.is_a?(String) && subject.present? && subject.bytesize <= MAXIMUM_IDENTIFIER_LENGTH && auth[:uid] == subject
          raise AuthenticationError, "invalid_subject"
        end
        valid_audience = claims["aud"] == Oidc.client_id ||
          (claims["aud"].is_a?(Array) && claims["aud"] == [ Oidc.client_id ])
        raise AuthenticationError, "invalid_audience" unless valid_audience
        if claims.key?("azp") &&
            (!authorized_party.is_a?(String) || authorized_party != Oidc.client_id)
          raise AuthenticationError, "invalid_authorized_party"
        end
        unless claims["exp"].is_a?(Integer) && claims["exp"] > now &&
            claims["iat"].is_a?(Integer) && claims["iat"].positive? && claims["iat"] <= now + CLOCK_SKEW &&
            claims["nonce"].is_a?(String) && claims["nonce"].present?
          raise AuthenticationError, "invalid_token_lifetime"
        end
        if claims["nbf"] && (!claims["nbf"].is_a?(Integer) || claims["nbf"] > now + CLOCK_SKEW)
          raise AuthenticationError, "invalid_token_lifetime"
        end
        validated_provider_session_id claims

        claims
      end

      def validated_provider_session_id(claims)
        return unless claims.key?("sid")

        sid = claims["sid"]
        unless sid.is_a?(String) && sid.present? && sid.bytesize <= MAXIMUM_IDENTIFIER_LENGTH
          raise AuthenticationError, "invalid_session_identifier"
        end

        sid
      end

      def raw_claims(auth)
        claims = auth.dig(:extra, :raw_info)&.to_h&.with_indifferent_access
        raise AuthenticationError, "missing_claims" unless claims

        claims
      end

      def validate_linking_authorization!(user, authorization, issuer, subject)
        unless authorization.is_a?(Hash)
          raise AuthenticationError, "password_reauthentication_required"
        end

        case authorization["method"]
        when "password"
          if user.identities.exists?(issuer:)
            raise AuthenticationError, "identity_conflict"
          end
        when "identity"
          expected_subject = authorization["subject"]
          unless expected_subject.is_a?(String) && expected_subject == subject &&
              user.identities.exists?(issuer:, subject: expected_subject)
            raise AuthenticationError, "identity_conflict"
          end
        else
          raise AuthenticationError, "password_reauthentication_required"
        end
      end

      def link_identity!(issuer:, subject:, claims:, linking_user:)
        email = verified_email!(claims)

        transaction do
          matching_user = user_matching(email)
          if matching_user && matching_user != linking_user
            raise AuthenticationError, "account_link_required"
          elsif linking_user && matching_user != linking_user
            raise AuthenticationError, "account_email_mismatch"
          end

          user = matching_user || provision_user!(email, claims["name"])
          user.lock!
          ensure_active_user! user
          unless user.email_address == email && user.normalized_email_address == email
            raise AuthenticationError, "account_email_mismatch"
          end

          if user.identities.where(issuer:).where.not(subject:).exists?
            raise AuthenticationError, "identity_conflict"
          end

          create!(
            user:, issuer:, subject:, provider_fingerprint: Oidc.provider_fingerprint,
            verified_configuration_fingerprint: Oidc.configuration.fingerprint,
            verified_at: Time.current,
            provisioned: matching_user.nil?
          )
        end
      end

      def authenticate_existing!(identity, claims, linking_user)
        identity = ensure_owned_and_active!(identity, linking_user)
        if identity.provider_fingerprint == Oidc.provider_fingerprint
          return mark_verified! identity
        end

        unless linking_user
          raise AuthenticationError, "provider_configuration_changed"
        end

        email = verified_email!(claims)
        unless linking_user.email_address == email && linking_user.normalized_email_address == email
          raise AuthenticationError, "account_email_mismatch"
        end

        identity.update!(
          provider_fingerprint: Oidc.provider_fingerprint,
          verified_configuration_fingerprint: Oidc.configuration.fingerprint,
          verified_at: Time.current
        )
        identity
      end

      def mark_verified!(identity)
        identity.update!(
          verified_configuration_fingerprint: Oidc.configuration.fingerprint,
          verified_at: Time.current
        )
        identity
      end

      def verified_email!(claims)
        email = User.normalize_email_address(claims["email"].to_s)
        unless claims["email_verified"] == true && email.match?(URI::MailTo::EMAIL_REGEXP) && email.bytesize <= 255
          raise AuthenticationError, "unverified_email"
        end

        email
      end

      def user_matching(email)
        User.where(email_address: email, normalized_email_address: email).sole
      rescue ActiveRecord::RecordNotFound
        nil
      rescue ActiveRecord::SoleRecordExceeded
        raise AuthenticationError, "ambiguous_email"
      end

      def provision_user!(email, name)
        raise AuthenticationError, "provisioning_disabled" unless Oidc.jit_provisioning?
        raise AuthenticationError, "first_run_required" unless Account.exists?

        User.create!(
          email_address: email,
          name: name.to_s.strip.first(255).presence || email.split("@", 2).first,
          password: SecureRandom.urlsafe_base64(48),
          role: :member
        )
      end

      def ensure_active!(identity)
        raise AuthenticationError, "identity_conflict" unless identity
        raise AuthenticationError, "identity_revoked" if identity.provider_revoked_at?

        ensure_active_user!(identity.user)
        identity
      end

      def ensure_owned_and_active!(identity, linking_user)
        if linking_user && identity&.user_id != linking_user.id
          raise AuthenticationError, "identity_conflict"
        end

        ensure_active! identity
      end

      def ensure_active_user!(user)
        raise AuthenticationError, "inactive_user" unless user.active?
      end
  end

  private
    def set_provider_fingerprint
      if provider_fingerprint.blank? && Oidc.enabled? && issuer == Oidc.issuer
        self.provider_fingerprint = Oidc.provider_fingerprint
      end
    end

    def set_scim_id
      self.scim_id ||= SecureRandom.uuid
    end

    def immutable_identity_binding
      if will_save_change_to_user_id? || will_save_change_to_issuer? ||
          will_save_change_to_subject? || will_save_change_to_scim_id?
        errors.add :base, "identity ownership and provider identifiers cannot change"
      end
    end

    def permanent_provider_revocation
      if provider_revoked_at_in_database.present? && will_save_change_to_provider_revoked_at?
        errors.add :provider_revoked_at, "cannot be changed once recorded"
      end
    end
end
