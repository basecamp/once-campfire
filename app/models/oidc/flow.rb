class Oidc::Flow < ApplicationRecord
  self.table_name = "oidc_flows"

  class Error < StandardError; end
  class AlreadyInProgress < Error; end
  class Invalid < Error; end

  Consumed = Data.define(
    :id, :finalization_token, :nonce, :pkce_verifier, :operation,
    :initiating_session_id, :linking_session_id, :return_to, :expires_at
  ) do
    def finalize!(&)
      Oidc::Flow.finalize! self, &
    end

    def abandon!
      Oidc::Flow.abandon! self
    end
  end

  OPERATIONS = %w[ authenticate link ].freeze
  PROCESSING_STATE_PREFIX = "processing:"

  validates :state_digest, :browser_digest, :configuration_fingerprint, :nonce,
    :pkce_verifier, :expires_at, presence: true
  validates :operation, inclusion: { in: OPERATIONS }

  scope :pending, -> { where(consumed_at: nil).where(expires_at: Time.current..) }

  class << self
    def start!(state:, nonce:, pkce_verifier:, browser_token:, initiating_session_id:, linking_intent:)
      now = Time.current
      operation = linking_intent ? "link" : "authenticate"
      linking_session_id = linking_intent&.fetch("session_id", nil)
      browser_digest = digest("browser", browser_token)
      expires_at = flow_expiration(linking_intent, now)

      transaction(requires_new: true) do
        where("expires_at <= ? OR (consumed_at IS NOT NULL AND state_digest NOT LIKE ?)",
          now, "#{PROCESSING_STATE_PREFIX}%").delete_all
        if active.where(browser_digest:).exists?
          raise AlreadyInProgress, "an OIDC flow is already active in this browser"
        end
        create!(
          state_digest: digest("state", state),
          browser_digest:,
          configuration_fingerprint: Oidc.configuration.fingerprint,
          nonce:,
          pkce_verifier:,
          operation:,
          initiating_session_id:,
          linking_session_id:,
          return_to: linking_intent&.fetch("return_to", nil),
          expires_at:
        )
      end
    rescue ActiveRecord::RecordNotUnique
      raise AlreadyInProgress, "an OIDC flow is already active in this browser"
    end

    def pending_for?(browser_token)
      browser_token.present? && active.exists?(browser_digest: digest("browser", browser_token))
    end

    def consume!(state:, browser_token:)
      raise Invalid, "the OIDC flow binding is missing" if state.blank? || browser_token.blank?

      now = Time.current
      transaction(requires_new: true) do
        flow = lock.where(
          state_digest: digest("state", state),
          browser_digest: digest("browser", browser_token),
          configuration_fingerprint: Oidc.configuration.fingerprint,
          consumed_at: nil
        ).where(expires_at: now..).first
        raise Invalid, "the OIDC flow is invalid, expired, or already consumed" unless flow

        finalization_token = SecureRandom.urlsafe_base64(32)
        consumed = Consumed.new(
          id: flow.id,
          finalization_token:,
          nonce: flow.nonce,
          pkce_verifier: flow.pkce_verifier,
          operation: flow.operation,
          initiating_session_id: flow.initiating_session_id,
          linking_session_id: flow.linking_session_id,
          return_to: flow.return_to,
          expires_at: flow.expires_at
        )
        flow.update_columns(
          state_digest: processing_state_digest(finalization_token),
          consumed_at: now,
          nonce: nil,
          pkce_verifier: nil,
          updated_at: now
        )
        consumed
      end
    end

    def cancel!(browser_token)
      return false if browser_token.blank?

      transaction(requires_new: true) do
        active.where(browser_digest: digest("browser", browser_token)).delete_all.positive?
      end
    end

    def finalize!(consumed)
      transaction(requires_new: true) do
        flow = processing_flow(consumed, lock: true)
        raise Invalid, "the OIDC flow was canceled, expired, or already finalized" unless flow

        yield.tap { flow.delete }
      end
    end

    def abandon!(consumed)
      where(
        id: consumed.id,
        state_digest: processing_state_digest(consumed.finalization_token)
      ).delete_all
    end

    private
      def active
        where(expires_at: Time.current..).where(
          "consumed_at IS NULL OR state_digest LIKE ?", "#{PROCESSING_STATE_PREFIX}%"
        )
      end

      def flow_expiration(linking_intent, now)
        flow_deadline = now + Oidc::FLOW_LIFETIME
        return flow_deadline unless linking_intent

        linking_deadline = Time.at(Integer(linking_intent.fetch("expires_at")))
        raise Invalid, "the linking authorization is expired" unless linking_deadline > now

        [ flow_deadline, linking_deadline ].min
      rescue KeyError, ArgumentError, TypeError
        raise Invalid, "the linking authorization expiry is invalid"
      end

      def processing_flow(consumed, lock:)
        relation = where(
          id: consumed.id,
          state_digest: processing_state_digest(consumed.finalization_token),
          configuration_fingerprint: Oidc.configuration.fingerprint
        ).where.not(consumed_at: nil).where(expires_at: Time.current..)
        relation = relation.lock if lock
        relation.first
      end

      def processing_state_digest(token)
        "#{PROCESSING_STATE_PREFIX}#{digest('processing', token)}"
      end

      def digest(purpose, value)
        Digest::SHA256.hexdigest [ purpose, value.to_s ].join("\0")
      end
  end
end
