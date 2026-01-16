class AddSingletonConstraintToAccounts < ActiveRecord::Migration[8.2]
  def change
    add_column :accounts, :singleton_guard, :integer, default: 0, null: false
    add_index :accounts, :singleton_guard, unique: true
  end
end
