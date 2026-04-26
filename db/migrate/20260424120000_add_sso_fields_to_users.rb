class AddSsoFieldsToUsers < ActiveRecord::Migration[8.2]
  def change
    add_column :users, :sso_provider, :string
    add_column :users, :sso_uid, :string
    add_index :users, [ :sso_provider, :sso_uid ], unique: true, where: "sso_provider IS NOT NULL"
  end
end
