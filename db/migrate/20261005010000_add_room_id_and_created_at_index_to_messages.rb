class AddRoomIdAndCreatedAtIndexToMessages < ActiveRecord::Migration[8.2]
  def change
    add_index :messages, %i[ room_id created_at ]
    remove_index :messages, :room_id
  end
end
