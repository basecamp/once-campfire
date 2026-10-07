class AddRoomIdAndCreatedAtIndexToMessages < ActiveRecord::Migration[8.2]
  def change
    add_index :messages, %i[ room_id created_at ], if_not_exists: true
  end
end
