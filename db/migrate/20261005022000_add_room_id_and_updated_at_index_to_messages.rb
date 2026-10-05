class AddRoomIdAndUpdatedAtIndexToMessages < ActiveRecord::Migration[8.2]
  def change
    add_index :messages, %i[ room_id updated_at ]
  end
end
