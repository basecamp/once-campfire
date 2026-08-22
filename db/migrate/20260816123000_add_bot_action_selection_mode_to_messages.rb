class AddBotActionSelectionModeToMessages < ActiveRecord::Migration[8.0]
  def change
    add_column :messages, :bot_action_selection_mode, :string, default: "none", null: false
  end
end
