require "campfire_backup/upgrade_recovery_guard"

CampfireBackup::UpgradeRecoveryGuard.install_active_record_guards!
ActiveSupport.on_load(:active_record_sqlite3adapter) do
  CampfireBackup::UpgradeRecoveryGuard.install_sqlite_connection_identity!(self)
end
