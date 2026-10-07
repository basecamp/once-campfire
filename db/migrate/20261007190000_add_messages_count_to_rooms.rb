class AddMessagesCountToRooms < ActiveRecord::Migration[8.2]
  def up
    unless column_exists?(:rooms, :messages_count)
      add_column :rooms, :messages_count, :integer, null: false, default: 0
    end

    # Backfill before installing triggers so the COUNT rewrite does not race with
    # concurrent inserts, and so we never rely on Rails callbacks for the tally.
    Room::MessagesCount.backfill!(connection)
    Room::MessagesCount.install!(connection)
  end

  def down
    Room::MessagesCount.uninstall!(connection)
    remove_column :rooms, :messages_count if column_exists?(:rooms, :messages_count)
  end
end
