class AddMissingIndexesForPerformance < ActiveRecord::Migration[8.0]
  def change
    # Membership lookups
    add_index :memberships, :room_id unless index_exists?(:memberships, :room_id)
    add_index :memberships, :user_id unless index_exists?(:memberships, :user_id)

    # Room creator lookups
    add_index :rooms, :creator_id unless index_exists?(:rooms, :creator_id)

    # Message ordering and pagination
    add_index :messages, :created_at unless index_exists?(:messages, :created_at)
    add_index :messages, [:room_id, :created_at] unless index_exists?(:messages, [:room_id, :created_at])

    # User status and role filters
    add_index :users, :status unless index_exists?(:users, :status)
    add_index :users, :role unless index_exists?(:users, :role)
  end
end
