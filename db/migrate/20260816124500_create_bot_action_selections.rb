class CreateBotActionSelections < ActiveRecord::Migration[8.0]
  def change
    create_table :bot_action_selections do |t|
      t.references :message, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.json :values, default: [], null: false
      t.timestamps

      t.index %i[ message_id user_id ], unique: true
    end
  end
end
