require "digest"

class RepairDirectRoomsAndPersistMessageOrigins < ActiveRecord::Migration[8.2]
  DIRECT_ROOM_CONSTRAINT_NAME = "rooms_direct_participant_key_type"
  DIRECT_ROOM_INDEX_NAME = "index_rooms_on_canonical_direct_participants"
  MESSAGE_ORIGIN_CONSTRAINT_NAME = "messages_origin"
  MESSAGE_ORIGINS = %w[ user bot_api webhook_reply ].freeze

  def up
    repair_direct_room_keys
    enforce_direct_room_key_contract
    persist_message_origins
  end

  def down
    raise ActiveRecord::IrreversibleMigration,
      "direct room identities and durable message origins are security records"
  end

  private
    def repair_direct_room_keys
      execute "UPDATE rooms SET direct_participant_key = NULL WHERE type <> 'Rooms::Direct'"

      select_values(<<~SQL).each do |room_id|
        SELECT id
        FROM rooms
        WHERE type = 'Rooms::Direct' AND direct_participant_key IS NULL
        ORDER BY id
      SQL
        participant_ids = select_values(<<~SQL).map(&:to_i).sort
          SELECT user_id
          FROM memberships
          WHERE room_id = #{connection.quote(room_id)}
        SQL
        canonical_key = "v1:#{Digest::SHA256.hexdigest(participant_ids.join(":"))}"
        key = direct_room_key_available?(canonical_key) ? canonical_key : repaired_key(room_id, canonical_key)

        execute <<~SQL
          UPDATE rooms
          SET direct_participant_key = #{connection.quote(key)}
          WHERE id = #{connection.quote(room_id)} AND direct_participant_key IS NULL
        SQL
      end
    end

    def repaired_key(room_id, canonical_key)
      base = "legacy:repair:#{room_id}:#{canonical_key}"
      candidate = base
      suffix = 0
      until direct_room_key_available?(candidate)
        suffix += 1
        candidate = "#{base}:#{suffix}"
      end
      candidate
    end

    def direct_room_key_available?(key)
      select_value(<<~SQL).to_i.zero?
        SELECT COUNT(*) FROM rooms
        WHERE direct_participant_key = #{connection.quote(key)}
      SQL
    end

    def enforce_direct_room_key_contract
      remove_check_constraint :rooms, name: DIRECT_ROOM_CONSTRAINT_NAME if
        check_constraint_exists?(:rooms, name: DIRECT_ROOM_CONSTRAINT_NAME)
      add_index :rooms, :direct_participant_key, unique: true,
        where: "direct_participant_key IS NOT NULL", name: DIRECT_ROOM_INDEX_NAME unless
        index_exists?(:rooms, :direct_participant_key, name: DIRECT_ROOM_INDEX_NAME)
      add_check_constraint :rooms,
        "(type = 'Rooms::Direct' AND direct_participant_key IS NOT NULL) OR " \
          "(type <> 'Rooms::Direct' AND direct_participant_key IS NULL)",
        name: DIRECT_ROOM_CONSTRAINT_NAME
    end

    def persist_message_origins
      add_column :messages, :origin, :string, null: false, default: "user" unless
        column_exists?(:messages, :origin)
      execute <<~SQL
        UPDATE messages
        SET origin = 'user'
        WHERE origin IS NULL OR origin NOT IN (#{MESSAGE_ORIGINS.map { connection.quote(_1) }.join(", ")})
      SQL
      change_column_default :messages, :origin, "user" unless
        connection.columns(:messages).find { _1.name == "origin" }&.default == "user"
      change_column_null :messages, :origin, false

      remove_check_constraint :messages, name: MESSAGE_ORIGIN_CONSTRAINT_NAME if
        check_constraint_exists?(:messages, name: MESSAGE_ORIGIN_CONSTRAINT_NAME)
      add_check_constraint :messages,
        "origin IN ('user', 'bot_api', 'webhook_reply')",
        name: MESSAGE_ORIGIN_CONSTRAINT_NAME
    end
end
