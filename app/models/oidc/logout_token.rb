require "digest"
require "oidc/logout_token_verifier"

class Oidc::LogoutToken < ApplicationRecord
  self.table_name = "oidc_logout_tokens"

  class Replay < StandardError; end

  validates :provider_fingerprint, :jti_digest,
    presence: true, length: { is: 64 }, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :expires_at, presence: true

  class << self
    def consume!(encoded_token, verifier: Oidc::LogoutTokenVerifier.new)
      claims = verifier.verify(encoded_token)
      user_ids = potentially_affected_user_ids(claims)

      User::MutationFence.with(user_ids) do
        transaction do
          prune_expired!
          Oidc::Revocation.prune_expired!
          Oidc::Revocation.record!(
            issuer: claims.fetch("iss"), subject: claims["sub"], sid: claims["sid"],
            issued_at: claims.fetch("iat")
          )
          create!(
            provider_fingerprint: Oidc.provider_fingerprint,
            jti_digest: Digest::SHA256.hexdigest(claims.fetch("jti")),
            expires_at: Time.at(
              claims.fetch("iat") + Oidc::LogoutTokenVerifier::MAXIMUM_AGE +
                Oidc::LogoutTokenVerifier::CLOCK_SKEW
            )
          )
          sessions_for(claims).destroy_all
        end
      end
      true
    rescue ActiveRecord::RecordNotUnique
      raise Replay, "logout token was already consumed"
    end

    def ready?
      table_exists? &&
        column_names.include?("provider_fingerprint") &&
        Session.column_names.include?("oidc_session_id") &&
        Session.column_names.include?("oidc_issued_at") &&
        Identity.column_names.include?("provider_revoked_at") &&
        Oidc::Revocation.ready?
    rescue ActiveRecord::ActiveRecordError
      false
    end

    private
      def potentially_affected_user_ids(claims)
        ids = []
        if claims["sub"]
          ids.concat current_identities.where(subject: claims["sub"]).pluck(:user_id)
        end
        if claims["sid"]
          ids.concat provider_sessions.where(oidc_session_id: claims["sid"]).pluck(:user_id)
        end
        ids.uniq
      end

      def sessions_for(claims)
        sessions = provider_sessions.lock
        matching = if sid = claims["sid"]
          sid_sessions = sessions.where(oidc_session_id: sid)
          identity_ids = sid_sessions.distinct.pluck(:identity_id)
          if identity_ids.many?
            raise Oidc::LogoutTokenVerifier::Invalid, "logout token session identifier is ambiguous"
          end

          if subject = claims["sub"]
            identity = current_identities.find_by(subject:)
            if identity_ids.any? && identity_ids != [ identity&.id ]
              raise Oidc::LogoutTokenVerifier::Invalid, "logout token subject and session do not match"
            end
            identity ? sid_sessions.where(identity_id: identity.id) : sid_sessions.none
          else
            sid_sessions
          end
        elsif identity = current_identities.find_by(subject: claims.fetch("sub"))
          sessions.where(identity_id: identity.id)
        else
          sessions.none
        end
        matching.where(oidc_issued_at: ..claims.fetch("iat"))
      end

      def current_identities
        Identity.where(issuer: Oidc.issuer, provider_fingerprint: Oidc.provider_fingerprint)
      end

      def provider_sessions
        Session.where(authentication_method: "oidc").joins(:identity).merge(current_identities)
      end

      def prune_expired!(limit: 100)
        expired_ids = where(expires_at: ...Time.current).order(:expires_at).limit(limit).select(:id)
        where(id: expired_ids).delete_all
      end
  end
end
