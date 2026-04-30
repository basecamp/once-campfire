class AddOidcIdTokenToSessions < ActiveRecord::Migration[8.2]
  def change
    add_column :sessions, :oidc_id_token, :text
  end
end
