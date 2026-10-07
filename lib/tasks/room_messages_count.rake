# Repair the database selected by each schema-load or migration operation.
# db:prepare calls DatabaseTasks directly, bypassing Rake enhancements;
# method hooks also run on every invocation.
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
