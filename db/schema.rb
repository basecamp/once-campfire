# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.2].define(version: 2026_08_03_000000) do
  create_table "accounts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "custom_styles"
    t.string "installation_identifier", null: false
    t.string "join_code", null: false
    t.string "name", null: false
    t.integer "oidc_break_glass_user_id"
    t.string "oidc_configuration_fingerprint"
    t.datetime "oidc_required_at"
    t.string "oidc_transition_state"
    t.datetime "oidc_verified_at"
    t.string "oidc_verified_configuration_fingerprint"
    t.json "settings"
    t.integer "singleton_guard", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["installation_identifier"], name: "index_accounts_on_installation_identifier", unique: true
    t.index ["oidc_break_glass_user_id"], name: "index_accounts_on_oidc_break_glass_user_id"
    t.index ["singleton_guard"], name: "index_accounts_on_singleton_guard", unique: true
    t.check_constraint "length(installation_identifier) = 32 AND installation_identifier NOT GLOB '*[^0-9a-f]*'", name: "accounts_installation_identifier"
    t.check_constraint "oidc_transition_state IS NULL OR oidc_transition_state = 'rollback_prepared'", name: "accounts_oidc_transition_state"
  end

  create_table "action_text_rich_texts", force: :cascade do |t|
    t.text "body"
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.datetime "updated_at", null: false
    t.index ["record_type", "record_id", "name"], name: "index_action_text_rich_texts_uniqueness", unique: true
  end

  create_table "active_storage_attachments", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.bigint "record_id", null: false
    t.string "record_type", null: false
    t.index ["blob_id"], name: "index_active_storage_attachments_on_blob_id"
    t.index ["record_type", "record_id", "name", "blob_id"], name: "index_active_storage_attachments_uniqueness", unique: true
  end

  create_table "active_storage_blobs", force: :cascade do |t|
    t.bigint "byte_size", null: false
    t.string "checksum"
    t.string "content_type"
    t.datetime "created_at", null: false
    t.string "filename", null: false
    t.string "key", null: false
    t.text "metadata"
    t.string "service_name", null: false
    t.index ["key"], name: "index_active_storage_blobs_on_key", unique: true
  end

  create_table "active_storage_variant_records", force: :cascade do |t|
    t.bigint "blob_id", null: false
    t.string "variation_digest", null: false
    t.index ["blob_id", "variation_digest"], name: "index_active_storage_variant_records_uniqueness", unique: true
  end

  create_table "ban_cleanup_blob_entries", force: :cascade do |t|
    t.integer "ban_cleanup_intent_id", null: false
    t.bigint "blob_id", null: false
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.string "service_name", null: false
    t.datetime "updated_at", null: false
    t.index ["ban_cleanup_intent_id", "blob_id"], name: "index_ban_cleanup_blob_entries_on_intent_and_blob", unique: true
    t.index ["ban_cleanup_intent_id"], name: "index_ban_cleanup_blob_entries_on_ban_cleanup_intent_id"
  end

  create_table "ban_cleanup_intents", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.bigint "blob_id_upper_bound"
    t.datetime "canceled_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "enqueued_at"
    t.datetime "failed_at"
    t.integer "generation", null: false
    t.datetime "last_error_at"
    t.string "last_error_class"
    t.text "last_error_message"
    t.string "lease_token"
    t.bigint "message_id_upper_bound"
    t.datetime "messages_deleted_at"
    t.datetime "next_attempt_at"
    t.bigint "owned_blob_id_cursor", default: 0, null: false
    t.datetime "purge_started_at"
    t.datetime "snapshot_completed_at"
    t.datetime "started_at"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["completed_at", "canceled_at", "failed_at", "next_attempt_at", "enqueued_at"], name: "index_ban_cleanup_intents_on_dispatch_state"
    t.index ["lease_token"], name: "index_ban_cleanup_intents_on_lease_token"
    t.index ["user_id", "generation"], name: "index_ban_cleanup_intents_on_user_id_and_generation", unique: true
    t.index ["user_id"], name: "index_ban_cleanup_intents_on_user_id"
    t.check_constraint "(completed_at IS NOT NULL) + (canceled_at IS NOT NULL) + (failed_at IS NOT NULL) <= 1", name: "ban_cleanup_intents_terminal_state"
    t.check_constraint "(lease_token IS NULL AND enqueued_at IS NULL AND started_at IS NULL) OR (lease_token IS NOT NULL AND enqueued_at IS NOT NULL)", name: "ban_cleanup_intents_lease"
    t.check_constraint "attempts >= 0", name: "ban_cleanup_intents_attempts"
    t.check_constraint "generation > 0", name: "ban_cleanup_intents_generation"
    t.check_constraint "owned_blob_id_cursor >= 0", name: "ban_cleanup_intents_blob_cursor"
  end

  create_table "bans", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["ip_address"], name: "index_bans_on_ip_address"
    t.index ["user_id"], name: "index_bans_on_user_id"
  end

  create_table "boosts", force: :cascade do |t|
    t.integer "booster_id", null: false
    t.string "content", limit: 16, null: false
    t.datetime "created_at", null: false
    t.integer "message_id", null: false
    t.datetime "updated_at", null: false
    t.index ["booster_id"], name: "index_boosts_on_booster_id"
    t.index ["message_id"], name: "index_boosts_on_message_id"
  end

  create_table "credential_intents", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "credential_digest"
    t.datetime "expires_at", null: false
    t.string "purpose", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id"
    t.index ["expires_at"], name: "index_credential_intents_on_expires_at"
    t.index ["token_digest"], name: "index_credential_intents_on_token_digest", unique: true
    t.index ["user_id"], name: "index_credential_intents_on_user_id"
    t.check_constraint "(purpose = 'join' AND user_id IS NULL AND credential_digest IS NOT NULL) OR (purpose IN ('transfer_grant', 'transfer') AND user_id IS NOT NULL AND credential_digest IS NOT NULL)", name: "credential_intents_attributes"
    t.check_constraint "credential_digest IS NULL OR (length(credential_digest) = 64 AND credential_digest NOT GLOB '*[^0-9a-f]*')", name: "credential_intents_credential_digest"
    t.check_constraint "length(token_digest) = 64 AND token_digest NOT GLOB '*[^0-9a-f]*'", name: "credential_intents_token_digest"
    t.check_constraint "purpose IN ('join', 'transfer_grant', 'transfer')", name: "credential_intents_purpose"
  end

  create_table "identities", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "issuer", null: false
    t.string "provider_fingerprint", null: false
    t.datetime "provider_revoked_at"
    t.boolean "provisioned", default: false, null: false
    t.string "scim_id", null: false
    t.string "subject", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.datetime "verified_at"
    t.string "verified_configuration_fingerprint"
    t.index ["id", "user_id"], name: "index_identities_on_id_and_user_id", unique: true
    t.index ["issuer", "subject"], name: "index_identities_on_issuer_and_subject", unique: true
    t.index ["scim_id"], name: "index_identities_on_scim_id", unique: true
    t.index ["user_id", "issuer"], name: "index_identities_on_user_id_and_issuer", unique: true
    t.index ["user_id"], name: "index_identities_on_user_id"
    t.check_constraint "length(scim_id) = 36 AND substr(scim_id, 9, 1) = '-' AND substr(scim_id, 14, 1) = '-' AND substr(scim_id, 19, 1) = '-' AND substr(scim_id, 24, 1) = '-' AND scim_id NOT GLOB '*[^0-9a-f-]*'", name: "identities_scim_id"
  end

  create_table "memberships", force: :cascade do |t|
    t.datetime "connected_at"
    t.datetime "created_at", null: false
    t.string "involvement", default: "mentions"
    t.integer "presence_generation", default: 0, null: false
    t.json "presence_tokens", default: {}, null: false
    t.integer "room_id", null: false
    t.datetime "unread_at"
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["room_id", "created_at"], name: "index_memberships_on_room_id_and_created_at"
    t.index ["room_id", "user_id"], name: "index_memberships_on_room_id_and_user_id", unique: true
    t.index ["room_id"], name: "index_memberships_on_room_id"
    t.index ["user_id"], name: "index_memberships_on_user_id"
  end

  create_table "message_effects", force: :cascade do |t|
    t.integer "attempts", default: 0, null: false
    t.datetime "canceled_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.string "deduplication_key", null: false
    t.string "delivery_id"
    t.string "effect", null: false
    t.datetime "enqueued_at"
    t.datetime "failed_at"
    t.datetime "last_error_at"
    t.string "last_error_class"
    t.text "last_error_message"
    t.string "lease_token"
    t.string "message_client_id", null: false
    t.integer "message_id", null: false
    t.datetime "next_attempt_at"
    t.integer "presence_generation"
    t.integer "recipient_id"
    t.integer "room_id", null: false
    t.datetime "started_at"
    t.datetime "updated_at", null: false
    t.string "webhook_generation"
    t.integer "webhook_id"
    t.index ["completed_at", "canceled_at", "failed_at", "next_attempt_at", "enqueued_at"], name: "index_message_effects_on_dispatch_state"
    t.index ["delivery_id"], name: "index_message_effects_on_delivery_id", unique: true, where: "delivery_id IS NOT NULL"
    t.index ["lease_token"], name: "index_message_effects_on_lease_token"
    t.index ["message_id", "deduplication_key"], name: "index_message_effects_on_message_id_and_deduplication_key", unique: true
    t.index ["message_id"], name: "index_message_effects_on_message_id"
    t.check_constraint "(completed_at IS NOT NULL) + (canceled_at IS NOT NULL) + (failed_at IS NOT NULL) <= 1", name: "message_effects_terminal_state"
    t.check_constraint "(effect = 'bot_webhook' AND webhook_id IS NOT NULL AND webhook_generation IS NOT NULL AND delivery_id IS NOT NULL) OR (effect <> 'bot_webhook' AND webhook_id IS NULL AND webhook_generation IS NULL AND delivery_id IS NULL)", name: "message_effects_webhook_delivery"
    t.check_constraint "(effect = 'presence_reconcile' AND presence_generation IS NOT NULL) OR (effect <> 'presence_reconcile' AND presence_generation IS NULL)", name: "message_effects_presence_generation"
    t.check_constraint "(effect IN ('bot_webhook', 'push_delivery', 'presence_reconcile') AND recipient_id IS NOT NULL) OR (effect NOT IN ('bot_webhook', 'push_delivery', 'presence_reconcile') AND recipient_id IS NULL)", name: "message_effects_recipient"
    t.check_constraint "(lease_token IS NULL AND enqueued_at IS NULL AND started_at IS NULL) OR (lease_token IS NOT NULL AND enqueued_at IS NOT NULL)", name: "message_effects_lease"
    t.check_constraint "attempts >= 0", name: "message_effects_attempts"
    t.check_constraint "effect IN ('room_receive', 'broadcast_create', 'broadcast_update', 'broadcast_destroy', 'push_delivery', 'presence_reconcile', 'webhook_fanout', 'bot_webhook')", name: "message_effects_kind"
    t.check_constraint "length(CAST(message_client_id AS BLOB)) <= 64", name: "message_effects_message_client_id_bytes"
  end

  create_table "messages", force: :cascade do |t|
    t.string "client_message_id", null: false
    t.datetime "created_at", null: false
    t.integer "creator_id", null: false
    t.integer "room_id", null: false
    t.datetime "updated_at", null: false
    t.index ["creator_id"], name: "index_messages_on_creator_id"
    t.index ["room_id", "client_message_id"], name: "index_messages_on_room_and_client_message_id", unique: true
    t.index ["room_id"], name: "index_messages_on_room_id"
    t.check_constraint "length(CAST(client_message_id AS BLOB)) BETWEEN 1 AND 64", name: "messages_client_message_id_bytes"
  end

  create_table "oidc_flows", force: :cascade do |t|
    t.string "browser_digest", null: false
    t.string "configuration_fingerprint", null: false
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.integer "initiating_session_id"
    t.integer "linking_session_id"
    t.string "nonce"
    t.string "operation", null: false
    t.string "pkce_verifier"
    t.string "return_to"
    t.string "state_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["browser_digest"], name: "index_oidc_flows_on_pending_browser", unique: true, where: "consumed_at IS NULL"
    t.index ["expires_at"], name: "index_oidc_flows_on_expires_at"
    t.index ["state_digest"], name: "index_oidc_flows_on_state_digest", unique: true
    t.check_constraint "operation IN ('authenticate', 'link')", name: "oidc_flows_operation"
  end

  create_table "oidc_logout_tokens", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "jti_digest", null: false
    t.string "provider_fingerprint", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_oidc_logout_tokens_on_expires_at"
    t.index ["provider_fingerprint", "jti_digest"], name: "index_oidc_logout_tokens_on_provider_and_jti", unique: true
    t.check_constraint "length(jti_digest) = 64 AND jti_digest NOT GLOB '*[^0-9a-f]*'", name: "oidc_logout_tokens_jti_digest"
    t.check_constraint "length(provider_fingerprint) = 64 AND provider_fingerprint NOT GLOB '*[^0-9a-f]*'", name: "oidc_logout_tokens_provider_fingerprint"
  end

  create_table "oidc_revocations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "identifier_digest", null: false
    t.string "identifier_type", null: false
    t.string "issuer_fingerprint", null: false
    t.integer "revoked_before"
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_oidc_revocations_on_expires_at"
    t.index ["issuer_fingerprint", "identifier_type", "identifier_digest"], name: "index_oidc_revocations_on_issuer_and_identifier", unique: true
    t.check_constraint "length(identifier_digest) = 64 AND identifier_digest NOT GLOB '*[^0-9a-f]*'", name: "oidc_revocations_identifier_digest"
    t.check_constraint "identifier_type IN ('sid', 'sub')", name: "oidc_revocations_identifier_type"
    t.check_constraint "length(issuer_fingerprint) = 64 AND issuer_fingerprint NOT GLOB '*[^0-9a-f]*'", name: "oidc_revocations_issuer_fingerprint"
    t.check_constraint "revoked_before IS NULL OR revoked_before > 0", name: "oidc_revocations_revoked_before"
  end

  create_table "push_subscriptions", force: :cascade do |t|
    t.string "auth_key"
    t.datetime "created_at", null: false
    t.string "endpoint"
    t.string "p256dh_key"
    t.integer "session_id"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["endpoint", "p256dh_key", "auth_key"], name: "idx_on_endpoint_p256dh_key_auth_key_7553014576"
    t.index ["session_id"], name: "index_push_subscriptions_on_session_id", unique: true, where: "session_id IS NOT NULL"
    t.index ["user_id"], name: "index_push_subscriptions_on_user_id"
  end

  create_table "rooms", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "creator_id", null: false
    t.string "direct_participant_key"
    t.string "name"
    t.string "type", null: false
    t.datetime "updated_at", null: false
    t.index ["direct_participant_key"], name: "index_rooms_on_canonical_direct_participants", unique: true, where: "direct_participant_key IS NOT NULL"
    t.check_constraint "type = 'Rooms::Direct' OR direct_participant_key IS NULL", name: "rooms_direct_participant_key_type"
  end

  create_table "searches", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "query", null: false
    t.datetime "updated_at", null: false
    t.integer "user_id", null: false
    t.index ["user_id"], name: "index_searches_on_user_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.string "authentication_method", default: "legacy", null: false
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.integer "identity_id"
    t.string "ip_address"
    t.datetime "last_active_at", null: false
    t.string "oidc_configuration_fingerprint"
    t.integer "oidc_issued_at"
    t.string "oidc_session_id"
    t.string "token", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.integer "user_id", null: false
    t.index ["expires_at"], name: "index_sessions_on_expires_at"
    t.index ["id", "user_id"], name: "index_sessions_on_id_and_user_id", unique: true
    t.index ["identity_id", "oidc_session_id"], name: "index_sessions_on_identity_and_oidc_session", where: "oidc_session_id IS NOT NULL"
    t.index ["identity_id"], name: "index_sessions_on_identity_id"
    t.index ["token"], name: "index_sessions_on_token", unique: true
    t.index ["user_id"], name: "index_sessions_on_user_id"
    t.check_constraint "(authentication_method = 'oidc' AND identity_id IS NOT NULL AND expires_at IS NOT NULL AND oidc_configuration_fingerprint IS NOT NULL) OR (authentication_method <> 'oidc' AND identity_id IS NULL AND oidc_configuration_fingerprint IS NULL)", name: "sessions_oidc_identity_and_expiry"
    t.check_constraint "(authentication_method = 'oidc' AND oidc_issued_at IS NOT NULL) OR (authentication_method <> 'oidc' AND oidc_issued_at IS NULL)", name: "sessions_oidc_issued_at_method"
    t.check_constraint "oidc_issued_at IS NULL OR oidc_issued_at > 0", name: "sessions_oidc_issued_at_positive"
    t.check_constraint "authentication_method = 'oidc' OR oidc_session_id IS NULL", name: "sessions_oidc_session_id_method"
    t.check_constraint "authentication_method IN ('legacy', 'password', 'oidc', 'transfer')", name: "sessions_authentication_method"
    t.check_constraint "oidc_session_id IS NULL OR (length(CAST(oidc_session_id AS BLOB)) BETWEEN 1 AND 255)", name: "sessions_oidc_session_id_bytes"
  end

  create_table "users", force: :cascade do |t|
    t.integer "authorization_generation", default: 0, null: false
    t.integer "ban_cleanup_generation", default: 0, null: false
    t.text "bio"
    t.string "bot_token"
    t.datetime "created_at", null: false
    t.string "email_address"
    t.string "name", null: false
    t.string "normalized_email_address"
    t.string "password_digest"
    t.integer "role", default: 0, null: false
    t.integer "status", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["bot_token"], name: "index_users_on_bot_token", unique: true
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
    t.index ["normalized_email_address"], name: "index_users_on_normalized_email_address", unique: true
  end

  create_table "webhooks", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "delivery_generation", null: false
    t.datetime "updated_at", null: false
    t.string "url"
    t.integer "user_id", null: false
    t.index ["delivery_generation"], name: "index_webhooks_on_delivery_generation", unique: true
    t.index ["user_id"], name: "index_webhooks_on_user_id"
  end

  add_foreign_key "accounts", "users", column: "oidc_break_glass_user_id"
  add_foreign_key "active_storage_attachments", "active_storage_blobs", column: "blob_id"
  add_foreign_key "active_storage_variant_records", "active_storage_blobs", column: "blob_id"
  add_foreign_key "ban_cleanup_blob_entries", "ban_cleanup_intents", on_delete: :cascade
  add_foreign_key "ban_cleanup_intents", "users", on_delete: :cascade
  add_foreign_key "bans", "users"
  add_foreign_key "boosts", "messages"
  add_foreign_key "credential_intents", "users", on_delete: :cascade
  add_foreign_key "identities", "users"
  add_foreign_key "messages", "rooms"
  add_foreign_key "messages", "users", column: "creator_id"
  add_foreign_key "push_subscriptions", "sessions", column: ["session_id", "user_id"], primary_key: ["id", "user_id"], on_delete: :cascade
  add_foreign_key "push_subscriptions", "users"
  add_foreign_key "searches", "users"
  add_foreign_key "sessions", "identities", column: ["identity_id", "user_id"], primary_key: ["id", "user_id"], on_delete: :cascade
  add_foreign_key "sessions", "users"
  add_foreign_key "webhooks", "users"

  # Virtual tables defined in this database.
  # Note that virtual tables may not work with other database engines. Be careful if changing database.
  create_virtual_table "message_search_index", "fts5", ["body", "tokenize=porter"]
end
