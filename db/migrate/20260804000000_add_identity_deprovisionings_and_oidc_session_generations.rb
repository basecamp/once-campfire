require "securerandom"

class AddIdentityDeprovisioningsAndOidcSessionGenerations < ActiveRecord::Migration[8.2]
  SUBJECT_DEPROVISIONING_SCIM_ID = "00000000-0000-0000-0000-000000000000"
  disable_ddl_transaction!

  def up
    connection.disable_referential_integrity do
      transaction do
        add_session_generation_storage
        reserve_subject_deprovisioning_scim_id
        add_identity_deprovisioning_storage
        backfill_identity_deprovisionings
        connection.check_all_foreign_keys_valid!
      end
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "identity deprovisionings and retired OIDC session generations are security records"
  end

  private
    def add_session_generation_storage
      add_column :accounts, :oidc_session_configuration_fingerprint, :string unless
        column_exists?(:accounts, :oidc_session_configuration_fingerprint)
      add_column :accounts, :oidc_session_generation, :integer, null: false, default: 0 unless
        column_exists?(:accounts, :oidc_session_generation)

      unless check_constraint_exists?(:accounts, name: "accounts_oidc_session_configuration_fingerprint")
        add_check_constraint :accounts,
          "oidc_session_configuration_fingerprint IS NULL OR " \
            "(length(oidc_session_configuration_fingerprint) = 64 AND " \
            "oidc_session_configuration_fingerprint NOT GLOB '*[^0-9a-f]*')",
          name: "accounts_oidc_session_configuration_fingerprint"
      end
      unless check_constraint_exists?(:accounts, name: "accounts_oidc_session_generation")
        add_check_constraint :accounts, "oidc_session_generation >= 0",
          name: "accounts_oidc_session_generation"
      end

      unless column_exists?(:sessions, :oidc_session_generation)
        retire_existing_oidc_sessions
        add_column :sessions, :oidc_session_generation, :integer
      end
      add_index :sessions, :oidc_session_generation unless index_exists?(:sessions, :oidc_session_generation)
      unless check_constraint_exists?(:sessions, name: "sessions_oidc_generation_method")
        add_check_constraint :sessions,
          "(authentication_method = 'oidc' AND oidc_session_generation IS NOT NULL AND " \
            "oidc_session_generation > 0) OR " \
            "(authentication_method <> 'oidc' AND oidc_session_generation IS NULL)",
          name: "sessions_oidc_generation_method"
      end
    end

    def retire_existing_oidc_sessions
      return unless table_exists?(:sessions) && column_exists?(:sessions, :authentication_method)

      if table_exists?(:push_subscriptions) && column_exists?(:push_subscriptions, :session_id)
        execute <<~SQL
          DELETE FROM push_subscriptions
          WHERE session_id IN (
            SELECT id FROM sessions WHERE authentication_method = 'oidc'
          )
        SQL
      end
      execute "DELETE FROM sessions WHERE authentication_method = 'oidc'"
    end

    def add_identity_deprovisioning_storage
      unless table_exists?(:identity_deprovisionings)
        create_table :identity_deprovisionings do |t|
          t.string :issuer, null: false
          t.string :subject, null: false
          t.datetime :deprovisioned_at, null: false
          t.timestamps

          t.index %i[ issuer subject ], unique: true,
            name: "index_identity_deprovisionings_on_issuer_and_subject"
        end
      end
      unless check_constraint_exists?(:identity_deprovisionings, name: "identity_deprovisionings_issuer_bytes")
        add_check_constraint :identity_deprovisionings,
          "length(CAST(issuer AS BLOB)) BETWEEN 1 AND 255",
          name: "identity_deprovisionings_issuer_bytes"
      end
      unless check_constraint_exists?(:identity_deprovisionings, name: "identity_deprovisionings_subject_bytes")
        add_check_constraint :identity_deprovisionings,
          "length(CAST(subject AS BLOB)) BETWEEN 1 AND 255",
          name: "identity_deprovisionings_subject_bytes"
      end
    end

    def reserve_subject_deprovisioning_scim_id
      return unless table_exists?(:identities) && column_exists?(:identities, :scim_id)

      select_values(<<~SQL).each do |id|
        SELECT id FROM identities
        WHERE scim_id = #{connection.quote(SUBJECT_DEPROVISIONING_SCIM_ID)}
      SQL
        replacement = SecureRandom.uuid while !replacement ||
          select_value("SELECT COUNT(*) FROM identities WHERE scim_id = #{connection.quote(replacement)}").to_i.positive?
        execute <<~SQL
          UPDATE identities
          SET scim_id = #{connection.quote(replacement)}
          WHERE id = #{connection.quote(id)}
        SQL
      end

      unless check_constraint_exists?(:identities, name: "identities_reserved_scim_id")
        add_check_constraint :identities,
          "scim_id <> '#{SUBJECT_DEPROVISIONING_SCIM_ID}'",
          name: "identities_reserved_scim_id"
      end
    end

    def backfill_identity_deprovisionings
      return unless column_exists?(:identities, :provider_revoked_at)

      execute <<~SQL
        INSERT INTO identity_deprovisionings
          (issuer, subject, deprovisioned_at, created_at, updated_at)
        SELECT issuer, subject, provider_revoked_at, provider_revoked_at, provider_revoked_at
        FROM identities
        WHERE provider_revoked_at IS NOT NULL
        ON CONFLICT(issuer, subject) DO NOTHING
      SQL
    end
end
