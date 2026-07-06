class AddAccountSettings < ActiveRecord::Migration[7.2]
  def change
    add_column :accounts, :settings, :json
  end
end
