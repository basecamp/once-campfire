class CreatePolls < ActiveRecord::Migration[8.0]
  def change
    create_table :polls do |t|
      t.references :message, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.boolean :multi_select, null: false, default: false
      t.datetime :closed_at

      t.timestamps
    end

    create_table :poll_options do |t|
      t.references :poll, null: false, foreign_key: { on_delete: :cascade }
      t.string :body, null: false, limit: 120
      t.integer :position, null: false

      t.timestamps
    end
    add_index :poll_options, [ :poll_id, :position ]

    create_table :poll_votes do |t|
      t.references :poll, null: false, foreign_key: { on_delete: :cascade }
      t.references :poll_option, null: false, foreign_key: { on_delete: :cascade }
      t.references :voter, null: false, foreign_key: { to_table: :users, on_delete: :cascade }

      t.timestamps
    end
    add_index :poll_votes, [ :poll_option_id, :voter_id ], unique: true
    add_index :poll_votes, [ :poll_id, :voter_id ]
  end
end
