class AddSsoFieldsToUsers < ActiveRecord::Migration[8.2]
  def change
    add_column :users, :sso_provider, :string
    add_column :users, :sso_uid, :string
    add_check_constraint :users,
      "(sso_provider IS NULL) = (sso_uid IS NULL)",
      name: "users_sso_provider_uid_presence_match"
    add_index :users, [ :sso_provider, :sso_uid ], unique: true, where: "sso_provider IS NOT NULL AND sso_uid IS NOT NULL"
  end
end
