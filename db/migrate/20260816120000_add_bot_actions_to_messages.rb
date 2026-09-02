class AddBotActionsToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :bot_actions, :json, default: [], null: false
  end
end
