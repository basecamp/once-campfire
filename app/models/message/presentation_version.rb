# Keeps messages.presentation_version moving whenever anything a message's
# fragment renders changes: the message row, its rich text body, its boosts, the
# creator or a booster, or the room's name. SQLite triggers do it, so the version
# moves for every writer — Rails, bulk SQL and foreign connections alike — and a
# fragment keyed by it (Message#cache_version) can be looked up from the message
# row alone, without loading and fingerprinting the rest first.
#
# Versions come from one counter that only increases, so a message never sees
# the same version twice: not after a REPLACE recreates its row, nor after a
# repair, either of which would otherwise let a fragment cached under an old
# version be served for new content.
#
# NULL means the fragment is not cached by version: messages with an attachment
# or embedded attachments (their presentation also depends on Active Storage
# processing state) and messages in direct rooms (whose name is the members').
# Those keep Rails' own key. Once NULL, a message stays NULL.
#
# schema.rb does not dump SQLite triggers; like Room::MessagesCount, ensure!
# reinstalls them after schema loads, migrations and at boot.
class Message::PresentationVersion
  # Advances the counter; NEXT_VERSION then reads it. No ON CONFLICT clause: a
  # REPLACE that fires these triggers would impose its own policy on them.
  ADVANCE = [
    "INSERT INTO message_presentation_sequences (id, value) SELECT 1, 0 WHERE NOT EXISTS (SELECT 1 FROM message_presentation_sequences)",
    "UPDATE message_presentation_sequences SET value = value + 1 WHERE id = 1"
  ].freeze
  NEXT_VERSION = "(SELECT value FROM message_presentation_sequences WHERE id = 1)"

  # Evaluated against the current state of the message row being updated.
  UNVERSIONED = <<~SQL.squish
    room_id IN (SELECT id FROM rooms WHERE type = 'Rooms::Direct')
    OR EXISTS (SELECT 1 FROM active_storage_attachments
               WHERE record_type = 'Message' AND record_id = messages.id)
    OR EXISTS (SELECT 1 FROM action_text_rich_texts
               WHERE record_type = 'Message' AND name = 'body' AND record_id = messages.id
                 AND instr(body, '<action-text-attachment') > 0)
  SQL

  # Gives the matching messages a new version, or NULL if they can no longer be
  # versioned. NULL versions stay NULL.
  def self.bump_statements(condition)
    ADVANCE + [ <<~SQL.squish ]
      UPDATE messages SET presentation_version = CASE WHEN #{UNVERSIONED} THEN NULL ELSE #{NEXT_VERSION} END
        WHERE presentation_version IS NOT NULL AND (#{condition})
    SQL
  end

  def self.bump(condition)
    bump_statements(condition).map { |statement| "#{statement};" }.join("\n")
  end

  MESSAGE_BODY = ->(row) { "#{row}.record_type = 'Message' AND #{row}.name = 'body'" }
  USER_MESSAGES = ->(user_id) { "creator_id = #{user_id} OR id IN (SELECT message_id FROM boosts WHERE booster_id = #{user_id})" }

  TRIGGERS = {
    "messages_ai_presentation_version" => <<~SQL,
      AFTER INSERT ON messages
      BEGIN
        #{bump "id = NEW.id"}
      END
    SQL
    "messages_au_presentation_version" => <<~SQL,
      AFTER UPDATE ON messages
      WHEN NEW.presentation_version IS OLD.presentation_version AND NEW.presentation_version IS NOT NULL
      BEGIN
        #{bump "id = NEW.id"}
      END
    SQL
    "rich_texts_ai_presentation_version" => <<~SQL,
      AFTER INSERT ON action_text_rich_texts
      WHEN #{MESSAGE_BODY["NEW"]}
      BEGIN
        #{bump "id = NEW.record_id"}
      END
    SQL
    "rich_texts_au_presentation_version" => <<~SQL,
      AFTER UPDATE ON action_text_rich_texts
      WHEN (#{MESSAGE_BODY["OLD"]}) OR (#{MESSAGE_BODY["NEW"]})
      BEGIN
        #{bump "(#{MESSAGE_BODY["OLD"]} AND id = OLD.record_id) OR (#{MESSAGE_BODY["NEW"]} AND id = NEW.record_id)"}
      END
    SQL
    "rich_texts_ad_presentation_version" => <<~SQL,
      AFTER DELETE ON action_text_rich_texts
      WHEN #{MESSAGE_BODY["OLD"]}
      BEGIN
        #{bump "id = OLD.record_id"}
      END
    SQL
    "boosts_ai_presentation_version" => <<~SQL,
      AFTER INSERT ON boosts
      BEGIN
        #{bump "id = NEW.message_id"}
      END
    SQL
    "boosts_au_presentation_version" => <<~SQL,
      AFTER UPDATE ON boosts
      BEGIN
        #{bump "id IN (OLD.message_id, NEW.message_id)"}
      END
    SQL
    "boosts_ad_presentation_version" => <<~SQL,
      AFTER DELETE ON boosts
      BEGIN
        #{bump "id = OLD.message_id"}
      END
    SQL
    "users_au_presentation_version" => <<~SQL,
      AFTER UPDATE ON users
      BEGIN
        #{bump USER_MESSAGES["NEW.id"]}
      END
    SQL
    "rooms_au_presentation_version" => <<~SQL,
      AFTER UPDATE OF name, type ON rooms
      WHEN NEW.name IS NOT OLD.name OR NEW.type IS NOT OLD.type
      BEGIN
        #{bump "room_id = NEW.id"}
      END
    SQL
    "attachments_ai_presentation_version" => <<~SQL,
      AFTER INSERT ON active_storage_attachments
      WHEN NEW.record_type IN ('Message', 'User')
      BEGIN
        #{bump "(NEW.record_type = 'Message' AND id = NEW.record_id) OR (NEW.record_type = 'User' AND (#{USER_MESSAGES["NEW.record_id"]}))"}
      END
    SQL
    "attachments_au_presentation_version" => <<~SQL,
      AFTER UPDATE ON active_storage_attachments
      WHEN OLD.record_type IN ('Message', 'User') OR NEW.record_type IN ('Message', 'User')
      BEGIN
        #{bump "(NEW.record_type = 'Message' AND id = NEW.record_id)
          OR (OLD.record_type = 'User' AND (#{USER_MESSAGES["OLD.record_id"]}))
          OR (NEW.record_type = 'User' AND (#{USER_MESSAGES["NEW.record_id"]}))"}
      END
    SQL
    "attachments_ad_presentation_version" => <<~SQL
      AFTER DELETE ON active_storage_attachments
      WHEN OLD.record_type = 'User'
      BEGIN
        #{bump USER_MESSAGES["OLD.record_id"]}
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

    # Every versioned message gets a new version, or NULL if it cannot be versioned;
    # NULL versions stay NULL. A repair runs it too, so versions only move forward.
    def backfill!(connection = ActiveRecord::Base.connection)
      bump_statements("1").each { |statement| connection.execute(statement) }
    end

    def ensure!(connection = ActiveRecord::Base.connection)
      return unless connection.adapter_name.match?(/sqlite/i)
      return unless connection.data_source_exists?(:messages)
      return unless connection.column_exists?(:messages, :presentation_version)
      return unless connection.data_source_exists?(:message_presentation_sequences)
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
