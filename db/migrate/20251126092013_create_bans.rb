class CreateBans < ActiveRecord::Migration[8.1]
  def change
    create_table :bans do |t|
      t.references :user, null: false, foreign_key: true
      t.string :ip_address, null: false
      t.timestamps
    end

    add_index :bans, :ip_address
  end
end
