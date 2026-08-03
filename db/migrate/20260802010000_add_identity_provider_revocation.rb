require "securerandom"

class AddIdentityProviderRevocation < ActiveRecord::Migration[8.2]
  # SQLite must disable foreign-key actions before the explicit atomic rebuild transaction starts.
  disable_ddl_transaction!

  def up
    connection.disable_referential_integrity do
      transaction do
        add_identity_revocation_columns
        remove_oidc_sessions_without_provider_provenance
        add_session_revocation_columns
        add_logout_token_storage
        add_revocation_watermark_storage
        connection.check_all_foreign_keys_valid!
      end
    end
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "provider revocations and logout watermarks are security records; restore a pre-migration backup instead"
  end

  private
    def add_identity_revocation_columns
      add_column :identities, :scim_id, :string unless column_exists?(:identities, :scim_id)
      add_column :identities, :provider_revoked_at, :datetime unless column_exists?(:identities, :provider_revoked_at)

      select_values("SELECT id FROM identities WHERE scim_id IS NULL ORDER BY id").each do |id|
        execute <<~SQL
          UPDATE identities
          SET scim_id = #{connection.quote(SecureRandom.uuid)}
          WHERE id = #{connection.quote(id)} AND scim_id IS NULL
        SQL
      end
      change_column_null :identities, :scim_id, false if nullable_column?(:identities, :scim_id)
      add_index :identities, :scim_id, unique: true unless index_exists?(:identities, :scim_id, unique: true)
      unless check_constraint_exists?(:identities, name: "identities_scim_id")
        add_check_constraint :identities,
          "length(scim_id) = 36 AND substr(scim_id, 9, 1) = '-' AND substr(scim_id, 14, 1) = '-' " \
            "AND substr(scim_id, 19, 1) = '-' AND substr(scim_id, 24, 1) = '-' " \
            "AND scim_id NOT GLOB '*[^0-9a-f-]*'",
          name: "identities_scim_id"
      end
    end

    def remove_oidc_sessions_without_provider_provenance
      condition = "authentication_method = 'oidc'"
      condition += " AND oidc_issued_at IS NULL" if column_exists?(:sessions, :oidc_issued_at)

      # Foreign-key actions are disabled for the atomic SQLite table rebuilds below.
      execute <<~SQL
        DELETE FROM push_subscriptions
        WHERE session_id IN (SELECT id FROM sessions WHERE #{condition})
      SQL
      execute "DELETE FROM sessions WHERE #{condition}"
    end

    def add_session_revocation_columns
      add_column :sessions, :oidc_session_id, :string unless column_exists?(:sessions, :oidc_session_id)
      add_column :sessions, :oidc_issued_at, :integer unless column_exists?(:sessions, :oidc_issued_at)

      unless index_exists?(:sessions, name: "index_sessions_on_identity_and_oidc_session")
        add_index :sessions, %i[ identity_id oidc_session_id ],
          where: "oidc_session_id IS NOT NULL", name: "index_sessions_on_identity_and_oidc_session"
      end
      unless check_constraint_exists?(:sessions, name: "sessions_oidc_session_id_method")
        add_check_constraint :sessions,
          "authentication_method = 'oidc' OR oidc_session_id IS NULL",
          name: "sessions_oidc_session_id_method"
      end
      unless check_constraint_exists?(:sessions, name: "sessions_oidc_session_id_bytes")
        add_check_constraint :sessions,
          "oidc_session_id IS NULL OR (length(CAST(oidc_session_id AS BLOB)) BETWEEN 1 AND 255)",
          name: "sessions_oidc_session_id_bytes"
      end
      unless check_constraint_exists?(:sessions, name: "sessions_oidc_issued_at_method")
        add_check_constraint :sessions,
          "(authentication_method = 'oidc' AND oidc_issued_at IS NOT NULL) OR " \
            "(authentication_method <> 'oidc' AND oidc_issued_at IS NULL)",
          name: "sessions_oidc_issued_at_method"
      end
      unless check_constraint_exists?(:sessions, name: "sessions_oidc_issued_at_positive")
        add_check_constraint :sessions,
          "oidc_issued_at IS NULL OR oidc_issued_at > 0",
          name: "sessions_oidc_issued_at_positive"
      end
    end

    def add_logout_token_storage
      unless table_exists?(:oidc_logout_tokens)
        create_table :oidc_logout_tokens do |t|
          t.string :provider_fingerprint, null: false
          t.string :jti_digest, null: false
          t.datetime :expires_at, null: false
          t.timestamps
        end
      end
      unless index_exists?(:oidc_logout_tokens, name: "index_oidc_logout_tokens_on_provider_and_jti")
        add_index :oidc_logout_tokens, %i[ provider_fingerprint jti_digest ], unique: true,
          name: "index_oidc_logout_tokens_on_provider_and_jti"
      end
      add_index :oidc_logout_tokens, :expires_at unless index_exists?(:oidc_logout_tokens, :expires_at)
      unless check_constraint_exists?(:oidc_logout_tokens, name: "oidc_logout_tokens_provider_fingerprint")
        add_check_constraint :oidc_logout_tokens,
          "length(provider_fingerprint) = 64 AND provider_fingerprint NOT GLOB '*[^0-9a-f]*'",
          name: "oidc_logout_tokens_provider_fingerprint"
      end
      unless check_constraint_exists?(:oidc_logout_tokens, name: "oidc_logout_tokens_jti_digest")
        add_check_constraint :oidc_logout_tokens,
          "length(jti_digest) = 64 AND jti_digest NOT GLOB '*[^0-9a-f]*'",
          name: "oidc_logout_tokens_jti_digest"
      end
    end

    def add_revocation_watermark_storage
      unless table_exists?(:oidc_revocations)
        create_table :oidc_revocations do |t|
          t.string :issuer_fingerprint, null: false
          t.string :identifier_type, null: false
          t.string :identifier_digest, null: false
          t.integer :revoked_before
          t.datetime :expires_at, null: false
          t.timestamps
        end
      end
      unless index_exists?(:oidc_revocations, name: "index_oidc_revocations_on_issuer_and_identifier")
        add_index :oidc_revocations, %i[ issuer_fingerprint identifier_type identifier_digest ],
          unique: true, name: "index_oidc_revocations_on_issuer_and_identifier"
      end
      add_index :oidc_revocations, :expires_at unless index_exists?(:oidc_revocations, :expires_at)
      unless check_constraint_exists?(:oidc_revocations, name: "oidc_revocations_issuer_fingerprint")
        add_check_constraint :oidc_revocations,
          "length(issuer_fingerprint) = 64 AND issuer_fingerprint NOT GLOB '*[^0-9a-f]*'",
          name: "oidc_revocations_issuer_fingerprint"
      end
      unless check_constraint_exists?(:oidc_revocations, name: "oidc_revocations_identifier_type")
        add_check_constraint :oidc_revocations,
          "identifier_type IN ('sid', 'sub')", name: "oidc_revocations_identifier_type"
      end
      unless check_constraint_exists?(:oidc_revocations, name: "oidc_revocations_identifier_digest")
        add_check_constraint :oidc_revocations,
          "length(identifier_digest) = 64 AND identifier_digest NOT GLOB '*[^0-9a-f]*'",
          name: "oidc_revocations_identifier_digest"
      end
      unless check_constraint_exists?(:oidc_revocations, name: "oidc_revocations_revoked_before")
        add_check_constraint :oidc_revocations,
          "revoked_before IS NULL OR revoked_before > 0", name: "oidc_revocations_revoked_before"
      end
    end

    def nullable_column?(table, column)
      connection.columns(table).find { _1.name == column.to_s }.null
    end
end
