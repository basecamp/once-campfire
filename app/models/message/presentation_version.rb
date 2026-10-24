# Keeps messages.presentation_version moving whenever anything a message's
# fragment renders changes: the message row, its rich text body, its boosts, the
# creator or a booster, or the room's name. SQLite triggers do it, so the version
# moves for every writer — Rails, bulk SQL and foreign connections alike — and a
# fragment keyed by it (Message#cache_version) can be looked up from the message
# row alone, without loading and fingerprinting the rest first.
#
# NULL means the fragment is not cached by version: messages with an attachment
# or embedded attachments (their presentation also depends on Active Storage
# processing state) and messages in direct rooms (whose name is the members').
# Those keep Rails' own key. Once NULL, a message stays NULL.
#
# schema.rb does not dump SQLite triggers; like Room::MessagesCount, ensure!
# reinstalls them after schema loads, migrations and at boot.
class Message::PresentationVersion
  TRIGGERS = {
    "messages_ai_presentation_version" => <<~SQL,
      AFTER INSERT ON messages
      WHEN (SELECT type FROM rooms WHERE id = NEW.room_id) = 'Rooms::Direct'
      BEGIN
        UPDATE messages SET presentation_version = NULL WHERE id = NEW.id;
      END
    SQL
    "messages_au_presentation_version" => <<~SQL,
      AFTER UPDATE ON messages
      WHEN NEW.presentation_version IS OLD.presentation_version
      BEGIN
        UPDATE messages SET presentation_version = presentation_version + 1 WHERE id = NEW.id;
      END
    SQL
    "rich_texts_ai_presentation_version" => <<~SQL,
      AFTER INSERT ON action_text_rich_texts
      WHEN NEW.record_type = 'Message' AND NEW.name = 'body'
      BEGIN
        UPDATE messages SET presentation_version =
          CASE WHEN instr(NEW.body, '<action-text-attachment') > 0 THEN NULL ELSE presentation_version + 1 END
          WHERE id = NEW.record_id;
      END
    SQL
    "rich_texts_au_presentation_version" => <<~SQL,
      AFTER UPDATE ON action_text_rich_texts
      WHEN NEW.record_type = 'Message' AND NEW.name = 'body'
      BEGIN
        UPDATE messages SET presentation_version =
          CASE WHEN instr(NEW.body, '<action-text-attachment') > 0 THEN NULL ELSE presentation_version + 1 END
          WHERE id = NEW.record_id;
      END
    SQL
    "rich_texts_ad_presentation_version" => <<~SQL,
      AFTER DELETE ON action_text_rich_texts
      WHEN OLD.record_type = 'Message' AND OLD.name = 'body'
      BEGIN
        UPDATE messages SET presentation_version = presentation_version + 1 WHERE id = OLD.record_id;
      END
    SQL
    "boosts_ai_presentation_version" => <<~SQL,
      AFTER INSERT ON boosts
      BEGIN
        UPDATE messages SET presentation_version = presentation_version + 1 WHERE id = NEW.message_id;
      END
    SQL
    "boosts_au_presentation_version" => <<~SQL,
      AFTER UPDATE ON boosts
      BEGIN
        UPDATE messages SET presentation_version = presentation_version + 1 WHERE id IN (OLD.message_id, NEW.message_id);
      END
    SQL
    "boosts_ad_presentation_version" => <<~SQL,
      AFTER DELETE ON boosts
      BEGIN
        UPDATE messages SET presentation_version = presentation_version + 1 WHERE id = OLD.message_id;
      END
    SQL
    "users_au_presentation_version" => <<~SQL,
      AFTER UPDATE ON users
      BEGIN
        UPDATE messages SET presentation_version = presentation_version + 1
          WHERE creator_id = NEW.id OR id IN (SELECT message_id FROM boosts WHERE booster_id = NEW.id);
      END
    SQL
    "rooms_au_presentation_version" => <<~SQL,
      AFTER UPDATE OF name, type ON rooms
      WHEN NEW.name IS NOT OLD.name OR NEW.type IS NOT OLD.type
      BEGIN
        UPDATE messages SET presentation_version =
          CASE WHEN NEW.type = 'Rooms::Direct' THEN NULL ELSE presentation_version + 1 END
          WHERE room_id = NEW.id;
      END
    SQL
    "attachments_ai_presentation_version" => <<~SQL,
      AFTER INSERT ON active_storage_attachments
      WHEN NEW.record_type IN ('Message', 'User')
      BEGIN
        UPDATE messages SET presentation_version = NULL
          WHERE NEW.record_type = 'Message' AND id = NEW.record_id;
        UPDATE messages SET presentation_version = presentation_version + 1
          WHERE NEW.record_type = 'User' AND (creator_id = NEW.record_id OR id IN (SELECT message_id FROM boosts WHERE booster_id = NEW.record_id));
      END
    SQL
    "attachments_ad_presentation_version" => <<~SQL
      AFTER DELETE ON active_storage_attachments
      WHEN OLD.record_type = 'User'
      BEGIN
        UPDATE messages SET presentation_version = presentation_version + 1
          WHERE creator_id = OLD.record_id OR id IN (SELECT message_id FROM boosts WHERE booster_id = OLD.record_id);
      END
    SQL
  }.freeze

  class << self
    def install!(connection = ActiveRecord::Base.connection)
      with_immediate_write(connection) do
        uninstall!(connection)
        create_triggers!(connection)
      end
    end

    def uninstall!(connection = ActiveRecord::Base.connection)
      TRIGGERS.each_key { |name| connection.execute("DROP TRIGGER IF EXISTS #{name}") }
    end

    # Versions start from zero; messages that cannot be cached by version start NULL.
    def backfill!(connection = ActiveRecord::Base.connection)
      connection.execute <<~SQL
        UPDATE messages SET presentation_version = CASE
          WHEN room_id IN (SELECT id FROM rooms WHERE type = 'Rooms::Direct')
            OR id IN (SELECT record_id FROM active_storage_attachments WHERE record_type = 'Message')
            OR id IN (SELECT record_id FROM action_text_rich_texts
                      WHERE record_type = 'Message' AND name = 'body' AND instr(body, '<action-text-attachment') > 0)
          THEN NULL ELSE 0 END
      SQL
    end

    def ensure!(connection = ActiveRecord::Base.connection)
      return unless connection.adapter_name.match?(/sqlite/i)
      return unless connection.data_source_exists?(:messages)
      return unless connection.column_exists?(:messages, :presentation_version)
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
      TRIGGERS.each_key.all? { |name| trigger_installed?(connection, name) }
    end

    private
      def with_immediate_write(connection)
        if connection.transaction_open?
          yield
        else
          connection.raw_connection.transaction(:immediate) { yield }
        end
      end

      def create_triggers!(connection)
        TRIGGERS.each { |name, body| connection.execute("CREATE TRIGGER #{name} #{body}") }
      end
  end
end
