require "campfire_backup/installation_identity"
require "campfire_backup/upgrade_recovery_guard"
require "digest"
require "email_address"
require "securerandom"
require "set"

class CreateIdentities < ActiveRecord::Migration[8.2]
  CLIENT_MESSAGE_ID_BYTES = 64
  LEGACY_BANNED_USER_STATUS = 2
  DIRECT_ROOM_INDEX_NAME = "index_rooms_on_canonical_direct_participants"
  DIRECT_ROOM_CONSTRAINT_NAME = "rooms_direct_participant_key_type"
  MESSAGE_CLIENT_ID_CONSTRAINT_NAME = "messages_client_message_id_bytes"
  MESSAGE_CLIENT_ID_INDEX_NAME = "index_messages_on_room_and_client_message_id"
  MESSAGE_EFFECT_CLIENT_ID_CONSTRAINT_NAME = "message_effects_message_client_id_bytes"
  NORMALIZED_EMAIL_INDEX_NAME = "index_users_on_normalized_email_address"

  def up
    CampfireBackup::UpgradeRecoveryGuard.verify_migration!(connection:)
    normalize_user_email_addresses!

    unless column_exists?(:accounts, :installation_identifier)
      add_column :accounts, :installation_identifier, :string
      marker = Pathname(ENV.fetch(
        "CAMPFIRE_INSTALLATION_IDENTIFIER_PATH",
        Rails.root.join("storage", "installation-identifier").to_s
      ))
      if marker.file?
        identifier = marker.read.strip
        unless CampfireBackup::InstallationIdentity.valid?(identifier)
          raise ActiveRecord::MigrationError, "storage/installation-identifier is invalid"
        end
      end
      identifier ||= CampfireBackup::InstallationIdentity.generate
      execute "UPDATE accounts SET installation_identifier = #{connection.quote(identifier)} WHERE installation_identifier IS NULL"
      change_column_null :accounts, :installation_identifier, false
    end
    add_index :accounts, :installation_identifier, unique: true unless index_exists?(:accounts, :installation_identifier)
    unless check_constraint_exists?(:accounts, name: "accounts_installation_identifier")
      add_check_constraint :accounts,
        "length(installation_identifier) = 32 AND installation_identifier NOT GLOB '*[^0-9a-f]*'",
        name: "accounts_installation_identifier"
    end

    create_table :identities do |t|
      t.references :user, null: false, foreign_key: true
      t.string :issuer, null: false
      t.string :subject, null: false
      t.string :provider_fingerprint, null: false
      t.string :verified_configuration_fingerprint
      t.datetime :verified_at
      t.boolean :provisioned, null: false, default: false
      t.timestamps

      t.index %i[ issuer subject ], unique: true
      t.index %i[ user_id issuer ], unique: true
      t.index %i[ id user_id ], unique: true
    end

    create_table :oidc_flows do |t|
      t.string :state_digest, null: false
      t.string :browser_digest, null: false
      t.string :configuration_fingerprint, null: false
      t.string :nonce
      t.string :pkce_verifier
      t.string :operation, null: false
      t.integer :initiating_session_id
      t.integer :linking_session_id
      t.string :return_to
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.timestamps

      t.index :state_digest, unique: true
      t.index :expires_at
      t.index :browser_digest, unique: true,
        where: "consumed_at IS NULL", name: "index_oidc_flows_on_pending_browser"
    end
    add_check_constraint :oidc_flows, "operation IN ('authenticate', 'link')", name: "oidc_flows_operation"
    reconcile_legacy_message_ids!
    add_check_constraint :messages,
      "length(CAST(client_message_id AS BLOB)) <= #{CLIENT_MESSAGE_ID_BYTES}",
      name: MESSAGE_CLIENT_ID_CONSTRAINT_NAME
    add_index :messages, %i[ room_id client_message_id ], unique: true,
      name: MESSAGE_CLIENT_ID_INDEX_NAME

    add_column :rooms, :direct_participant_key, :string
    backfill_canonical_direct_rooms!
    add_index :rooms, :direct_participant_key, unique: true,
      where: "direct_participant_key IS NOT NULL", name: DIRECT_ROOM_INDEX_NAME
    add_check_constraint :rooms,
      "type = 'Rooms::Direct' OR direct_participant_key IS NULL", name: DIRECT_ROOM_CONSTRAINT_NAME

    add_column :memberships, :presence_generation, :integer, null: false, default: 0
    add_column :memberships, :presence_tokens, :json, null: false, default: {}
    execute "UPDATE memberships SET connected_at = NULL"
    remove_column :memberships, :connections

    add_column :webhooks, :delivery_generation, :string
    select_values("SELECT id FROM webhooks").each do |id|
      execute <<~SQL
        UPDATE webhooks
        SET delivery_generation = #{connection.quote(SecureRandom.uuid)}
        WHERE id = #{connection.quote(id)}
      SQL
    end
    change_column_null :webhooks, :delivery_generation, false
    add_index :webhooks, :delivery_generation, unique: true

    create_table :message_effects do |t|
      t.references :message, null: false
      t.integer :room_id, null: false
      t.string :message_client_id, null: false
      t.string :effect, null: false
      t.string :deduplication_key, null: false
      t.integer :recipient_id
      t.integer :presence_generation
      t.integer :webhook_id
      t.string :webhook_generation
      t.string :delivery_id
      t.string :lease_token
      t.datetime :enqueued_at
      t.datetime :started_at
      t.datetime :next_attempt_at
      t.datetime :completed_at
      t.datetime :canceled_at
      t.datetime :failed_at
      t.integer :attempts, null: false, default: 0
      t.string :last_error_class
      t.text :last_error_message
      t.datetime :last_error_at
      t.timestamps

      t.index %i[ message_id deduplication_key ], unique: true
      t.index %i[ completed_at canceled_at failed_at next_attempt_at enqueued_at ], name: "index_message_effects_on_dispatch_state"
      t.index :delivery_id, unique: true, where: "delivery_id IS NOT NULL"
      t.index :lease_token
    end
    add_check_constraint :message_effects,
      "effect IN ('room_receive', 'broadcast_create', 'broadcast_update', 'broadcast_destroy', " \
        "'push_delivery', 'presence_reconcile', 'webhook_fanout', 'bot_webhook')",
      name: "message_effects_kind"
    add_check_constraint :message_effects,
      "length(CAST(message_client_id AS BLOB)) <= #{CLIENT_MESSAGE_ID_BYTES}",
      name: MESSAGE_EFFECT_CLIENT_ID_CONSTRAINT_NAME
    add_check_constraint :message_effects,
      "(effect IN ('bot_webhook', 'push_delivery', 'presence_reconcile') AND recipient_id IS NOT NULL) OR " \
        "(effect NOT IN ('bot_webhook', 'push_delivery', 'presence_reconcile') AND recipient_id IS NULL)",
      name: "message_effects_recipient"
    add_check_constraint :message_effects,
      "(effect = 'bot_webhook' AND webhook_id IS NOT NULL AND webhook_generation IS NOT NULL AND delivery_id IS NOT NULL) OR " \
        "(effect <> 'bot_webhook' AND webhook_id IS NULL AND webhook_generation IS NULL AND delivery_id IS NULL)",
      name: "message_effects_webhook_delivery"
    add_check_constraint :message_effects,
      "(effect = 'presence_reconcile' AND presence_generation IS NOT NULL) OR " \
        "(effect <> 'presence_reconcile' AND presence_generation IS NULL)",
      name: "message_effects_presence_generation"
    add_check_constraint :message_effects, "attempts >= 0", name: "message_effects_attempts"
    add_check_constraint :message_effects,
      "(lease_token IS NULL AND enqueued_at IS NULL AND started_at IS NULL) OR " \
        "(lease_token IS NOT NULL AND enqueued_at IS NOT NULL)",
      name: "message_effects_lease"
    add_check_constraint :message_effects,
      "(completed_at IS NOT NULL) + (canceled_at IS NOT NULL) + (failed_at IS NOT NULL) <= 1",
      name: "message_effects_terminal_state"

    add_column :accounts, :oidc_configuration_fingerprint, :string
    add_column :accounts, :oidc_required_at, :datetime
    add_column :accounts, :oidc_verified_configuration_fingerprint, :string
    add_column :accounts, :oidc_verified_at, :datetime
    add_column :accounts, :oidc_transition_state, :string
    add_reference :accounts, :oidc_break_glass_user, foreign_key: { to_table: :users }
    add_check_constraint :accounts,
      "oidc_transition_state IS NULL OR oidc_transition_state = 'rollback_prepared'",
      name: "accounts_oidc_transition_state"

    add_reference :sessions, :identity
    add_column :sessions, :expires_at, :datetime
    add_column :sessions, :oidc_configuration_fingerprint, :string
    add_column :sessions, :authentication_method, :string, default: "legacy", null: false
    add_index :sessions, :expires_at
    add_index :sessions, %i[ id user_id ], unique: true
    add_check_constraint :sessions,
      "authentication_method IN ('legacy', 'password', 'oidc', 'transfer')",
      name: "sessions_authentication_method"
    add_check_constraint :sessions,
      "(authentication_method = 'oidc' AND identity_id IS NOT NULL AND expires_at IS NOT NULL " \
        "AND oidc_configuration_fingerprint IS NOT NULL) OR " \
        "(authentication_method <> 'oidc' AND identity_id IS NULL AND oidc_configuration_fingerprint IS NULL)",
      name: "sessions_oidc_identity_and_expiry"

    add_foreign_key :sessions, :identities,
      column: %i[ identity_id user_id ], primary_key: %i[ id user_id ],
      on_delete: :cascade, name: "fk_sessions_identity_owner"

    add_column :users, :authorization_generation, :integer, null: false, default: 0
    add_column :users, :ban_cleanup_generation, :integer, null: false, default: 0

    create_table :ban_cleanup_intents do |t|
      t.references :user, null: false, foreign_key: { on_delete: :cascade }
      t.integer :generation, null: false
      t.datetime :purge_started_at
      t.bigint :message_id_upper_bound
      t.bigint :blob_id_upper_bound
      t.bigint :owned_blob_id_cursor, null: false, default: 0
      t.datetime :messages_deleted_at
      t.datetime :snapshot_completed_at
      t.string :lease_token
      t.datetime :enqueued_at
      t.datetime :started_at
      t.datetime :next_attempt_at
      t.datetime :completed_at
      t.datetime :canceled_at
      t.datetime :failed_at
      t.integer :attempts, null: false, default: 0
      t.string :last_error_class
      t.text :last_error_message
      t.datetime :last_error_at
      t.timestamps

      t.index %i[ user_id generation ], unique: true
      t.index %i[ completed_at canceled_at failed_at next_attempt_at enqueued_at ], name: "index_ban_cleanup_intents_on_dispatch_state"
      t.index :lease_token
    end
    create_table :ban_cleanup_blob_entries do |t|
      t.references :ban_cleanup_intent, null: false, foreign_key: { on_delete: :cascade }
      t.bigint :blob_id, null: false
      t.string :key, null: false
      t.string :service_name, null: false
      t.timestamps

      t.index %i[ ban_cleanup_intent_id blob_id ], unique: true,
        name: "index_ban_cleanup_blob_entries_on_intent_and_blob"
    end
    add_check_constraint :ban_cleanup_intents, "generation > 0", name: "ban_cleanup_intents_generation"
    add_check_constraint :ban_cleanup_intents, "attempts >= 0", name: "ban_cleanup_intents_attempts"
    add_check_constraint :ban_cleanup_intents, "owned_blob_id_cursor >= 0", name: "ban_cleanup_intents_blob_cursor"
    add_check_constraint :ban_cleanup_intents,
      "(lease_token IS NULL AND enqueued_at IS NULL AND started_at IS NULL) OR " \
        "(lease_token IS NOT NULL AND enqueued_at IS NOT NULL)",
      name: "ban_cleanup_intents_lease"
    add_check_constraint :ban_cleanup_intents,
      "(completed_at IS NOT NULL) + (canceled_at IS NOT NULL) + (failed_at IS NOT NULL) <= 1",
      name: "ban_cleanup_intents_terminal_state"
    backfill_legacy_ban_cleanup_intents!

    add_reference :push_subscriptions, :session,
      index: { unique: true, where: "session_id IS NOT NULL" }
    add_foreign_key :push_subscriptions, :sessions,
      column: %i[ session_id user_id ], primary_key: %i[ id user_id ],
      on_delete: :cascade, name: "fk_push_subscriptions_session_owner"
  end

  def down
    CampfireBackup::UpgradeRecoveryGuard.authorize_destructive_rollback!(migration: self.class.name)

    if select_value("SELECT COUNT(*) FROM identities").to_i.positive? ||
        select_value("SELECT COUNT(*) FROM sessions WHERE authentication_method <> 'legacy'").to_i.positive? ||
        pending_reliable_work?
      raise ActiveRecord::IrreversibleMigration,
        "remove OIDC sessions and identities and complete durable work before reverting this migration"
    end

    remove_foreign_key :push_subscriptions, column: %i[ session_id user_id ]
    remove_reference :push_subscriptions, :session

    drop_table :ban_cleanup_blob_entries
    drop_table :ban_cleanup_intents
    remove_column :users, :ban_cleanup_generation
    remove_column :users, :authorization_generation
    remove_index :users, name: NORMALIZED_EMAIL_INDEX_NAME
    remove_column :users, :normalized_email_address

    remove_foreign_key :sessions, column: %i[ identity_id user_id ]
    remove_check_constraint :sessions, name: "sessions_oidc_identity_and_expiry"
    remove_check_constraint :sessions, name: "sessions_authentication_method"
    remove_index :sessions, %i[ id user_id ]
    remove_index :sessions, :expires_at
    remove_column :sessions, :authentication_method
    remove_column :sessions, :oidc_configuration_fingerprint
    remove_column :sessions, :expires_at
    remove_reference :sessions, :identity

    remove_column :accounts, :oidc_required_at
    remove_column :accounts, :oidc_configuration_fingerprint
    remove_column :accounts, :oidc_verified_at
    remove_column :accounts, :oidc_verified_configuration_fingerprint
    remove_reference :accounts, :oidc_break_glass_user, foreign_key: { to_table: :users }
    remove_check_constraint :accounts, name: "accounts_oidc_transition_state"
    remove_column :accounts, :oidc_transition_state
    drop_table :message_effects
    remove_index :webhooks, :delivery_generation
    remove_column :webhooks, :delivery_generation
    add_column :memberships, :connections, :integer, null: false, default: 0
    remove_column :memberships, :presence_tokens
    remove_column :memberships, :presence_generation
    execute "UPDATE memberships SET connected_at = NULL"
    remove_check_constraint :rooms, name: DIRECT_ROOM_CONSTRAINT_NAME
    remove_index :rooms, name: DIRECT_ROOM_INDEX_NAME
    remove_column :rooms, :direct_participant_key
    remove_check_constraint :messages, name: MESSAGE_CLIENT_ID_CONSTRAINT_NAME
    remove_index :messages, name: MESSAGE_CLIENT_ID_INDEX_NAME
    drop_table :oidc_flows
    drop_table :identities
  end

  private
    def normalize_user_email_addresses!
      users = select_all("SELECT id, email_address FROM users ORDER BY id").map do |row|
        [ row.fetch("id"), EmailAddress.normalize(row.fetch("email_address")) ]
      end
      collision_ids = users.group_by(&:last).filter_map do |email_address, entries|
        entries.map(&:first) if email_address && entries.many?
      end
      if collision_ids.any?
        formatted_ids = collision_ids.map { |ids| ids.join(", ") }.join("; ")
        raise ActiveRecord::MigrationError,
          "email normalization collision between user ids: #{formatted_ids}"
      end

      add_column :users, :normalized_email_address, :string
      users.each do |id, email_address|
        execute <<~SQL
          UPDATE users
          SET email_address = #{connection.quote(email_address)},
              normalized_email_address = #{connection.quote(email_address)}
          WHERE id = #{connection.quote(id)}
        SQL
      end
      add_index :users, :normalized_email_address, unique: true, name: NORMALIZED_EMAIL_INDEX_NAME
    end

    def backfill_legacy_ban_cleanup_intents!
      execute <<~SQL
        UPDATE users
        SET ban_cleanup_generation = 1
        WHERE status = #{LEGACY_BANNED_USER_STATUS} AND ban_cleanup_generation = 0
      SQL
      execute <<~SQL
        INSERT INTO ban_cleanup_intents (user_id, generation, created_at, updated_at)
        SELECT id, 1, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP
        FROM users
        WHERE status = #{LEGACY_BANNED_USER_STATUS} AND ban_cleanup_generation = 1
        ON CONFLICT(user_id, generation) DO NOTHING
      SQL
    end

    def pending_reliable_work?
      select_value("SELECT COUNT(*) FROM message_effects WHERE completed_at IS NULL AND canceled_at IS NULL").to_i.positive? ||
        select_value(<<~SQL).to_i.positive?
          SELECT COUNT(*)
          FROM ban_cleanup_intents
          WHERE completed_at IS NULL AND canceled_at IS NULL
        SQL
    end

    def reconcile_legacy_message_ids!
      rows_requiring_new_ids = select_all(<<~SQL)
        SELECT message.id, message.room_id, message.creator_id
        FROM messages message
        WHERE length(CAST(message.client_message_id AS BLOB)) > #{CLIENT_MESSAGE_ID_BYTES}
          OR EXISTS (
            SELECT 1
            FROM messages earlier
            WHERE earlier.room_id = message.room_id
              AND earlier.client_message_id = message.client_message_id
              AND earlier.id < message.id
          )
        ORDER BY message.id
      SQL

      rows_requiring_new_ids.each do |row|
        base = "__campfire_legacy_duplicate_#{row.fetch('id')}"
        replacement = base
        suffix = 0
        while replacement_message_id_exists?(row, replacement)
          suffix += 1
          replacement = "#{base}_#{suffix}"
        end

        execute <<~SQL
          UPDATE messages
          SET client_message_id = #{connection.quote(replacement)}
          WHERE id = #{connection.quote(row.fetch('id'))}
        SQL
      end
    end

    def backfill_canonical_direct_rooms!
      claimed_keys = Set.new
      select_values("SELECT id FROM rooms WHERE type = 'Rooms::Direct' ORDER BY id").each do |room_id|
        participant_ids = select_values(<<~SQL).map(&:to_i).sort
          SELECT user_id FROM memberships WHERE room_id = #{connection.quote(room_id)}
        SQL
        key = "v1:#{Digest::SHA256.hexdigest(participant_ids.join(":"))}"
        next unless claimed_keys.add?(key)

        execute <<~SQL
          UPDATE rooms
          SET direct_participant_key = #{connection.quote(key)}
          WHERE id = #{connection.quote(room_id)}
        SQL
      end
    end

    def replacement_message_id_exists?(row, replacement)
      select_value(<<~SQL).to_i.positive?
        SELECT COUNT(*)
        FROM messages
        WHERE room_id = #{connection.quote(row.fetch('room_id'))}
          AND client_message_id = #{connection.quote(replacement)}
          AND id <> #{connection.quote(row.fetch('id'))}
      SQL
    end
end
