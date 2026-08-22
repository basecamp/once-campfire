require "campfire_backup/upgrade_recovery_guard"

class CreateCredentialIntents < ActiveRecord::Migration[8.2]
  def up
    create_table :credential_intents do |t|
      t.string :purpose, null: false
      t.string :token_digest, null: false
      t.string :credential_digest
      t.references :user, foreign_key: { on_delete: :cascade }
      t.datetime :expires_at, null: false
      t.timestamps

      t.index :token_digest, unique: true
      t.index :expires_at
    end

    add_check_constraint :credential_intents,
      "purpose IN ('join', 'transfer_grant', 'transfer')", name: "credential_intents_purpose"
    add_check_constraint :credential_intents,
      "(purpose = 'join' AND user_id IS NULL AND credential_digest IS NOT NULL) OR " \
        "(purpose IN ('transfer_grant', 'transfer') AND user_id IS NOT NULL AND credential_digest IS NULL)",
      name: "credential_intents_attributes"
    add_check_constraint :credential_intents,
      "length(token_digest) = 64 AND token_digest NOT GLOB '*[^0-9a-f]*'",
      name: "credential_intents_token_digest"
    add_check_constraint :credential_intents,
      "credential_digest IS NULL OR (length(credential_digest) = 64 AND credential_digest NOT GLOB '*[^0-9a-f]*')",
      name: "credential_intents_credential_digest"
  end

  def down
    CampfireBackup::UpgradeRecoveryGuard.authorize_destructive_rollback!(migration: self.class.name)

    drop_table :credential_intents
  end
end
