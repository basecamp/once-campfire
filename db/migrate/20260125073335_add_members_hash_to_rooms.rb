class AddMembersHashToRooms < ActiveRecord::Migration[8.2]
  def change
    add_column :rooms, :members_hash, :string
    add_index :rooms, :members_hash

    # Backfill existing direct rooms
    reversible do |dir|
      dir.up do
        Rooms::Direct.includes(:users).find_each do |room|
          room.update_column(:members_hash, room.compute_members_hash)
        end
      end
    end
  end
end
