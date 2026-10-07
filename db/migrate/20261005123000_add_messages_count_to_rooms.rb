class AddMessagesCountToRooms < ActiveRecord::Migration[8.2]
  def up
    add_column :rooms, :messages_count, :integer, null: false, default: 0

    execute <<~SQL
      UPDATE rooms SET messages_count = (
        SELECT COUNT(*) FROM messages WHERE messages.room_id = rooms.id
      )
    SQL
  end

  def down
    remove_column :rooms, :messages_count
  end
end
