# Keeps rooms.messages_count correct for every SQLite writer — Rails, bulk SQL,
# and foreign connections — without ActiveRecord counter_cache callbacks that
# those paths skip (and that would double-count if combined with triggers).
class Room::MessagesCount
  INSERT_TRIGGER = "messages_ai_rooms_messages_count"
  DELETE_TRIGGER = "messages_ad_rooms_messages_count"
  UPDATE_TRIGGER = "messages_au_rooms_messages_count"
  TRIGGERS = [ INSERT_TRIGGER, DELETE_TRIGGER, UPDATE_TRIGGER ].freeze

  class << self
    def install!(connection = ActiveRecord::Base.connection)
      with_immediate_write(connection) do
        replace_triggers!(connection)
      end
    end

    def uninstall!(connection = ActiveRecord::Base.connection)
      TRIGGERS.each do |name|
        connection.execute("DROP TRIGGER IF EXISTS #{name}")
      end
    end

    def backfill!(connection = ActiveRecord::Base.connection)
      connection.execute <<~SQL
        UPDATE rooms SET messages_count = (
          SELECT COUNT(*) FROM messages WHERE messages.room_id = rooms.id
        )
      SQL
    end

    # schema.rb does not dump SQLite triggers; reinstall after schema:load.
    # Repair rechecks, rebuilds counts, and installs triggers in one write txn
    # so concurrent writers and concurrent boot repairs cannot observe a gap.
    def ensure!(connection = ActiveRecord::Base.connection)
      return unless connection.adapter_name.match?(/sqlite/i)
      return unless connection.data_source_exists?(:rooms)
      return unless connection.column_exists?(:rooms, :messages_count)
      return if triggers_installed?(connection)

      with_immediate_write(connection) do
        next if triggers_installed?(connection)

        uninstall!(connection)
        backfill!(connection)
        create_triggers!(connection)
      end
    end

    def trigger_installed?(connection, name)
      connection.select_value(
        "SELECT 1 FROM sqlite_master WHERE type = 'trigger' AND name = #{connection.quote(name)}"
      ).present?
    end

    def triggers_installed?(connection = ActiveRecord::Base.connection)
      TRIGGERS.all? { |name| trigger_installed?(connection, name) }
    end

    private
      def with_immediate_write(connection)
        if connection.transaction_open?
          yield
        else
          connection.raw_connection.transaction(:immediate) { yield }
        end
      end

      def replace_triggers!(connection)
        uninstall!(connection)
        create_triggers!(connection)
      end

      def create_triggers!(connection)
        connection.execute <<~SQL
          CREATE TRIGGER #{INSERT_TRIGGER} AFTER INSERT ON messages
          BEGIN
            UPDATE rooms SET messages_count = messages_count + 1 WHERE id = NEW.room_id;
          END
        SQL
        connection.execute <<~SQL
          CREATE TRIGGER #{DELETE_TRIGGER} AFTER DELETE ON messages
          BEGIN
            UPDATE rooms SET messages_count = messages_count - 1 WHERE id = OLD.room_id;
          END
        SQL
        connection.execute <<~SQL
          CREATE TRIGGER #{UPDATE_TRIGGER} AFTER UPDATE OF room_id ON messages
          WHEN OLD.room_id IS NOT NEW.room_id
          BEGIN
            UPDATE rooms SET messages_count = messages_count - 1 WHERE id = OLD.room_id;
            UPDATE rooms SET messages_count = messages_count + 1 WHERE id = NEW.room_id;
          END
        SQL
      end
  end
end
