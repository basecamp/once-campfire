# Repair while DatabaseTasks still selects the database it loaded or migrated.
# db:prepare calls these methods directly, and test tasks restore their original
# pool before a Rake enhancement runs. This also avoids Rake's once-only invoke.
module RoomMessagesCountDatabaseTasks
  def load_schema(...)
    super.tap { repair_room_messages_count }
  end

  def migrate(...)
    super.tap { repair_room_messages_count }
  end

  private
    def repair_room_messages_count
      migration_connection_pool.with_connection do |connection|
        Room::MessagesCount.ensure!(connection)
      end
    end
end

ActiveRecord::Tasks::DatabaseTasks.singleton_class.prepend(RoomMessagesCountDatabaseTasks)

namespace :room_messages_count do
  task ensure: :environment do
    ActiveRecord::Base.connection_pool.with_connection do |connection|
      Room::MessagesCount.ensure!(connection)
    end
  end
end
