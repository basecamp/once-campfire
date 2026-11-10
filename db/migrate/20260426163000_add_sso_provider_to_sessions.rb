class AddSsoProviderToSessions < ActiveRecord::Migration[8.2]
  def change
    add_column :sessions, :sso_provider, :string
  end
end
