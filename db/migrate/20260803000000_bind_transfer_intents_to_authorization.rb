require "campfire_backup/upgrade_recovery_guard"

class BindTransferIntentsToAuthorization < ActiveRecord::Migration[8.2]
  CONSTRAINT_NAME = "credential_intents_attributes"

  def up
    remove_check_constraint :credential_intents, name: CONSTRAINT_NAME
    execute "DELETE FROM credential_intents WHERE purpose IN ('transfer_grant', 'transfer')"
    add_check_constraint :credential_intents,
      "(purpose = 'join' AND user_id IS NULL AND credential_digest IS NOT NULL) OR " \
        "(purpose IN ('transfer_grant', 'transfer') AND user_id IS NOT NULL AND credential_digest IS NOT NULL)",
      name: CONSTRAINT_NAME
  end

  def down
    CampfireBackup::UpgradeRecoveryGuard.authorize_destructive_rollback!(migration: self.class.name)

    remove_check_constraint :credential_intents, name: CONSTRAINT_NAME
    execute "UPDATE credential_intents SET credential_digest = NULL WHERE purpose IN ('transfer_grant', 'transfer')"
    add_check_constraint :credential_intents,
      "(purpose = 'join' AND user_id IS NULL AND credential_digest IS NOT NULL) OR " \
        "(purpose IN ('transfer_grant', 'transfer') AND user_id IS NOT NULL AND credential_digest IS NULL)",
      name: CONSTRAINT_NAME
  end
end
