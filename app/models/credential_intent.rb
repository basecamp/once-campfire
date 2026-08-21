require "digest"
require "openssl"

class CredentialIntent < ApplicationRecord
  class Invalid < StandardError; end

  PURPOSES = %w[ join transfer_grant transfer ].freeze
  BROWSER_INTENT_LIFETIME = 30.minutes
  TOKEN_PATTERN = /\A[0-9a-f]{64}\z/

  belongs_to :user, optional: true

  validates :purpose, inclusion: { in: PURPOSES }
  validates :token_digest, presence: true, uniqueness: true, format: { with: TOKEN_PATTERN }
  validates :credential_digest, format: { with: TOKEN_PATTERN }, allow_nil: true
  validate :attributes_match_purpose

  class << self
    def issue_join!(join_code)
      issue!(purpose: "join", credential_digest: join_credential_digest(join_code))
    end

    def issue_transfer_grant!(user, expires_in:)
      ensure_transfer_available!
      issue!(
        purpose: "transfer_grant", user:, expires_in:,
        credential_digest: transfer_credential_digest(user)
      )
    end

    def exchange_transfer!(token)
      ensure_transfer_available!
      consume_record!(token, purpose: "transfer_grant") do |grant|
        user = User.active.find(grant.user_id)
        unless secure_compare(grant.credential_digest, transfer_credential_digest(user))
          raise Invalid, "transfer credential was revoked"
        end
        issue!(purpose: "transfer", user:, credential_digest: grant.credential_digest)
      end
    rescue ActiveRecord::RecordNotFound
      raise Invalid, "transfer credential is invalid"
    end

    def consume_join!(token, account:)
      consume_record!(token, purpose: "join") do |intent|
        unless secure_compare(intent.credential_digest, join_credential_digest(account.join_code))
          raise Invalid, "join credential is no longer valid"
        end

        yield
      end
    end

    def consume_transfer!(token)
      ensure_transfer_available!
      consume_record!(token, purpose: "transfer") do |intent|
        user = User.active.find(intent.user_id)
        unless secure_compare(intent.credential_digest, transfer_credential_digest(user))
          raise Invalid, "transfer intent was revoked"
        end
        yield user
      end
    rescue ActiveRecord::RecordNotFound
      raise Invalid, "transfer intent is invalid"
    end

    def valid_join?(token, account:)
      intent = active_record_for(token, purpose: "join")
      intent && secure_compare(intent.credential_digest, join_credential_digest(account.join_code))
    end

    def valid_transfer?(token)
      return false if Oidc.enabled?

      intent = active_record_for(token, purpose: "transfer")
      return false unless intent

      user = User.active.find_by(id: intent.user_id)
      user && secure_compare(intent.credential_digest, transfer_credential_digest(user))
    end

    private
      def issue!(purpose:, user: nil, credential_digest: nil, expires_in: BROWSER_INTENT_LIFETIME)
        prune_expired!
        loop do
          token = SecureRandom.urlsafe_base64(32)
          create!(
            purpose:, user:, credential_digest:,
            token_digest: token_digest(token, purpose:), expires_at: expires_in.from_now
          )
          return token
        rescue ActiveRecord::RecordNotUnique
          next
        end
      end

      def consume_record!(token, purpose:)
        transaction(requires_new: true) do
          digest = token_digest(token, purpose:)
          intent = find_by(token_digest: digest, purpose:)
          raise Invalid, "credential intent is invalid or expired" unless intent&.expires_at&.future?

          consumed = where(id: intent.id, token_digest: digest, purpose:, expires_at: Time.current..).delete_all
          raise Invalid, "credential intent was already consumed" unless consumed == 1

          yield intent
        end
      end

      def active_record_for(token, purpose:)
        return if token.blank?

        find_by(token_digest: token_digest(token, purpose:), purpose:, expires_at: Time.current..)
      end

      def token_digest(token, purpose:)
        Digest::SHA256.hexdigest [ purpose, token.to_s ].join("\0")
      end

      def join_credential_digest(join_code)
        OpenSSL::HMAC.hexdigest(
          "SHA256", Rails.application.key_generator.generate_key("credential-intent/join", 32), join_code.to_s
        )
      end

      def transfer_credential_digest(user)
        Digest::SHA256.hexdigest(
          [ user.id, user.authorization_generation, user.password_digest ].join("\0")
        )
      end

      def ensure_transfer_available!
        raise Invalid, "session transfer is unavailable while single sign-on is enabled" if Oidc.enabled?
      end

      def secure_compare(left, right)
        left.present? && right.present? && left.bytesize == right.bytesize &&
          ActiveSupport::SecurityUtils.secure_compare(left, right)
      end

      def prune_expired!
        expired_ids = where(expires_at: ..Time.current).order(:expires_at).limit(100).select(:id)
        where(id: expired_ids).delete_all
      end
  end

  private
    def attributes_match_purpose
      valid = if purpose == "join"
        user_id.nil? && credential_digest.present?
      else
        user_id.present? && credential_digest.present?
      end
      errors.add :base, "credential intent attributes do not match its purpose" unless valid
    end
end
