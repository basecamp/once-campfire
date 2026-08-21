class Identity::Deprovisioning < ApplicationRecord
  self.table_name = "identity_deprovisionings"

  UNIQUE_INDEX = "index_identity_deprovisionings_on_issuer_and_subject"

  validates :issuer, :subject, presence: true,
    length: { maximum: Identity::MAXIMUM_IDENTIFIER_LENGTH }
  validates :subject, uniqueness: { scope: :issuer }
  validates :deprovisioned_at, presence: true
  validate :immutable_tombstone, on: :update
  before_destroy :prevent_tombstone_destruction

  class << self
    def blocked?(issuer:, subject:)
      exists?(issuer:, subject:)
    end

    def deprovision!(issuer:, subject:, expected_identity: nil)
      validate_identifiers! issuer, subject
      identity = nil
      user = nil
      changed = false

      User::MutationFence.with_identity_subject(issuer:, subject:) do
        candidate = Identity.find_by(issuer:, subject:)
        ensure_expected_identity! candidate, expected_identity

        User::MutationFence.with_administrator_roster do
          User::MutationFence.with(candidate&.user_id) do
            transaction do
              identity = Identity.lock.find_by(issuer:, subject:)
              ensure_expected_identity! identity, expected_identity
              tombstone = record!(issuer:, subject:)
              if identity
                user = identity.user
                changed = user.send(
                  :apply_identity_provider_deactivation!, identity:, issuer:,
                  revoked_at: tombstone.deprovisioned_at
                )
              end
            end
          end
        end
      end

      user&.disconnect_remote_connections(reason: Session::REVOKED_REASON) if changed
      identity&.reload
    end

    def ready?
      table_exists? && column_names.include?("deprovisioned_at")
    rescue ActiveRecord::ActiveRecordError
      false
    end

    private
      def record!(issuer:, subject:)
        now = Time.current
        insert_all(
          [ { issuer:, subject:, deprovisioned_at: now, created_at: now, updated_at: now } ],
          unique_by: UNIQUE_INDEX
        )
        lock.find_by!(issuer:, subject:)
      end

      def validate_identifiers!(issuer, subject)
        [ issuer, subject ].each do |identifier|
          unless identifier.is_a?(String) && identifier.present? &&
              identifier.bytesize <= Identity::MAXIMUM_IDENTIFIER_LENGTH
            raise ArgumentError, "identity provider identifier is invalid"
          end
        end
      end

      def ensure_expected_identity!(identity, expected_identity)
        return unless expected_identity
        return if identity&.id == expected_identity.id && identity.user_id == expected_identity.user_id &&
          identity.scim_id == expected_identity.scim_id

        raise ActiveRecord::RecordNotFound, "identity is no longer available"
      end
  end

  private
    def immutable_tombstone
      errors.add :base, "identity deprovisioning tombstones cannot change" if changed_attribute_names_to_save.any?
    end

    def prevent_tombstone_destruction
      errors.add :base, "identity deprovisioning tombstones cannot be destroyed"
      throw :abort
    end
end
