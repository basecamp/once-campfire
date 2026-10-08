class CreateSolidCacheEntries < ActiveRecord::Migration[8.2]
  def change
    create_table :solid_cache_entries do |t|
      t.binary :key, limit: 1024, null: false
      t.binary :value, limit: 536_870_912, null: false
      t.datetime :created_at, null: false
      t.integer :key_hash, limit: 8, null: false
      t.integer :byte_size, limit: 4, null: false

      t.index :byte_size
      t.index [ :key_hash, :byte_size ]
      t.index :key_hash, unique: true
    end
  end
end
