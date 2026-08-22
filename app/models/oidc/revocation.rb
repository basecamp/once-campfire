require "digest"
require "oidc/logout_token_verifier"

class Oidc::Revocation < ApplicationRecord
  self.table_name = "oidc_revocations"

  IDENTIFIER_TYPES = %w[ sid sub ].freeze
  RETENTION = Oidc::FLOW_LIFETIME + Oidc::LogoutTokenVerifier::CLOCK_SKEW.seconds
  UNIQUE_INDEX = "index_oidc_revocations_on_issuer_and_identifier"

  validates :issuer_fingerprint, :identifier_digest,
    presence: true, length: { is: 64 }, format: { with: /\A[0-9a-f]{64}\z/ }
  validates :identifier_type, inclusion: { in: IDENTIFIER_TYPES }
  validates :revoked_before, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :expires_at, presence: true

  class << self
    def guard_session!(issuer:, subject:, sid:, issued_at:)
      issued_at = Integer(issued_at)
      raise Identity::AuthenticationError, "invalid_token_lifetime" unless issued_at.positive?

      rows = lock_identifiers!(issuer:, subject:, sid:)
      if rows.any? { _1.revoked_before && issued_at <= _1.revoked_before }
        raise Identity::AuthenticationError, "provider_session_revoked"
      end

      true
    rescue ArgumentError, TypeError
      raise Identity::AuthenticationError, "invalid_token_lifetime"
    end

    def record!(issuer:, subject:, sid:, issued_at:)
      issued_at = Integer(issued_at)
      raise ArgumentError, "revocation issue time must be positive" unless issued_at.positive?

      rows = lock_identifiers!(issuer:, subject:, sid:)
      now = Time.current
      expires_at = RETENTION.from_now
      rows.each do |row|
        row.update_columns(
          revoked_before: [ row.revoked_before, issued_at ].compact.max,
          expires_at: [ row.expires_at, expires_at ].max,
          updated_at: now
        )
      end
      rows
    end

    def prune_expired!(limit: 100)
      expired_ids = where(expires_at: ...Time.current).order(:expires_at).limit(limit).select(:id)
      where(id: expired_ids).delete_all
    end

    def ready?
      table_exists? && column_names.include?("revoked_before")
    rescue ActiveRecord::ActiveRecordError
      false
    end

    private
      def lock_identifiers!(issuer:, subject:, sid:)
        keys = identifier_keys(issuer:, subject:, sid:)
        raise ArgumentError, "a subject or session identifier is required" if keys.empty?

        now = Time.current
        expires_at = RETENTION.from_now
        insert_all(
          keys.map do |key|
            key.merge(expires_at:, created_at: now, updated_at: now)
          end,
          unique_by: UNIQUE_INDEX
        )
        keys.map { |key| lock.find_by!(key) }
      end

      def identifier_keys(issuer:, subject:, sid:)
        issuer_fingerprint = Digest::SHA256.hexdigest(issuer.to_s)
        { "sid" => sid, "sub" => subject }.filter_map do |identifier_type, identifier|
          if identifier.present?
            {
              issuer_fingerprint:,
              identifier_type:,
              identifier_digest: Digest::SHA256.hexdigest(identifier)
            }
          end
        end.sort_by { [ _1.fetch(:identifier_type), _1.fetch(:identifier_digest) ] }
      end
  end
end
