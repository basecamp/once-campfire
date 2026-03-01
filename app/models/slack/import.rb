require "cgi"
require "json"
require "set"
require "zip"

class Slack::Import
  Result = Struct.new(:rooms_created, :rooms_touched, :messages_imported, :messages_skipped, keyword_init: true)

  class InvalidArchiveError < StandardError; end
  class InvalidMappingsError < StandardError; end

  MESSAGE_ENTRY_PATTERN = %r{\A(?<channel>[^/]+)/\d{4}-\d{2}-\d{2}\.json\z}
  IMPORT_BOT_NAME = "Slack Import Bot"

  def initialize(archive:, importer:, user_mappings: nil)
    @archive = archive
    @importer = importer
    @user_mappings = user_mappings
  end

  def call
    Zip::File.open(archive_path) do |zip|
      import_from(zip)
    end
  rescue Zip::Error
    raise InvalidArchiveError, "Could not read Slack export ZIP."
  end

  private
    attr_reader :archive, :importer, :user_mappings

    def import_from(zip)
      slack_users = parse_optional_json_file(zip, "users.json")
      channels_by_id = load_channels_by_id(zip)

      users_by_slack_id = slack_users.each_with_object({}) do |user, result|
        result[user["id"]] = user if user.is_a?(Hash) && user["id"].present?
      end
      explicit_user_mappings

      rooms_created = 0
      messages_imported = 0
      messages_skipped = 0
      rooms_touched = Set.new
      latest_message_at_by_room_id = {}
      room_cache = {}

      message_entries_from(zip).each do |entry|
        channel_name = channel_name_from(entry.name)
        next if channel_name.blank?

        room_key = channel_name.downcase
        room, created_room = room_cache.fetch(room_key) do
          find_or_create_room(channel_name)
        end
        room_cache[room_key] = [ room, false ]
        rooms_created += 1 if created_room

        prepared_messages = prepare_messages(
          entry:,
          room:,
          channel_name:,
          channels_by_id:,
          users_by_slack_id:
        )

        existing_client_message_ids = room.messages.where(client_message_id: prepared_messages.pluck(:client_message_id)).pluck(:client_message_id).to_set

        new_messages = prepared_messages.reject do |message_attributes|
          next false unless existing_client_message_ids.include?(message_attributes[:client_message_id])
          messages_skipped += 1
          true
        end

        inserted_count = insert_messages(new_messages)
        next if inserted_count.zero?

        messages_imported += inserted_count
        rooms_touched << room.id
        latest_message_at_by_room_id[room.id] = [ latest_message_at_by_room_id[room.id], new_messages.max_by { |message| message[:created_at] }[:created_at] ].compact.max
      end

      latest_message_at_by_room_id.each do |room_id, latest_message_at|
        Room.where(id: room_id).where("updated_at < ?", latest_message_at).update_all(updated_at: latest_message_at)
      end

      Result.new(
        rooms_created:,
        rooms_touched: rooms_touched.length,
        messages_imported:,
        messages_skipped:
      )
    end

    def prepare_messages(entry:, room:, channel_name:, channels_by_id:, users_by_slack_id:)
      raw_messages = parse_json_entry(entry)
      return [] unless raw_messages.is_a?(Array)

      raw_messages.filter_map do |raw_message|
        prepare_message(
          raw_message:,
          room:,
          channel_name:,
          channels_by_id:,
          users_by_slack_id:
        )
      end
    end

    def prepare_message(raw_message:, room:, channel_name:, channels_by_id:, users_by_slack_id:)
      return unless raw_message.is_a?(Hash) && raw_message["type"] == "message"

      created_at = parse_timestamp(raw_message["ts"])
      return unless created_at

      body = normalize_text(raw_message["text"], channels_by_id:, users_by_slack_id:)
      return if body.blank?

      creator, speaker_name = resolve_creator(raw_message, users_by_slack_id:)
      body = "[#{speaker_name}] #{body}" if creator == import_bot && speaker_name.present?

      {
        body:,
        channel_name:,
        client_message_id: client_message_id_for(channel_name, raw_message["ts"]),
        created_at:,
        creator_id: creator.id,
        room_id: room.id,
        updated_at: created_at
      }
    end

    def insert_messages(messages)
      return 0 if messages.empty?

      message_rows = messages.map do |message|
        message.slice(:room_id, :creator_id, :client_message_id, :created_at, :updated_at)
      end

      Message.insert_all!(message_rows)

      room_id = messages.first[:room_id]
      client_message_ids = messages.pluck(:client_message_id)
      message_ids_by_client_message_id = Message.where(room_id:, client_message_id: client_message_ids).pluck(:id, :client_message_id).to_h { |id, client_message_id| [ client_message_id, id ] }

      rich_text_rows = messages.map do |message|
        message_id = message_ids_by_client_message_id.fetch(message[:client_message_id])
        {
          body: message[:body],
          created_at: message[:created_at],
          name: "body",
          record_id: message_id,
          record_type: "Message",
          updated_at: message[:updated_at]
        }
      end

      ActionText::RichText.insert_all!(rich_text_rows)
      insert_in_search_index(rich_text_rows)

      messages.length
    end

    def insert_in_search_index(rich_text_rows)
      rich_text_rows.each do |row|
        sql = Message.sanitize_sql [ "insert into message_search_index(rowid, body) values (?, ?)", row[:record_id], row[:body].to_s ]
        Message.connection.execute(sql)
      end
    end

    def resolve_creator(raw_message, users_by_slack_id:)
      slack_user = users_by_slack_id[raw_message["user"]]
      local_user =
        mapped_user_for(raw_message:, slack_user:) ||
        find_local_user(slack_user) ||
        find_local_user("name" => raw_message["username"])
      speaker_name = display_name_for(slack_user) || raw_message["username"]

      [ local_user || import_bot, speaker_name ]
    end

    def mapped_user_for(raw_message:, slack_user:)
      mapping_keys_for(raw_message:, slack_user:).each do |mapping_key|
        mapped_user = explicit_user_mappings[normalize_mapping_key(mapping_key)]
        return mapped_user if mapped_user
      end

      nil
    end

    def mapping_keys_for(raw_message:, slack_user:)
      [
        raw_message["user"],
        raw_message["username"],
        slack_user&.dig("profile", "email"),
        slack_user&.dig("profile", "display_name"),
        slack_user&.dig("profile", "real_name"),
        slack_user&.fetch("real_name", nil),
        slack_user&.fetch("name", nil)
      ].compact_blank
    end

    def explicit_user_mappings
      @explicit_user_mappings ||= begin
        mappings = {}

        user_mappings.to_s.each_line.with_index(1) do |line, line_number|
          line = line.strip
          next if line.blank?

          slack_identifier, campfire_identifier = line.split("=", 2).map { |value| value&.strip }
          if slack_identifier.blank? || campfire_identifier.blank?
            raise InvalidMappingsError, "Invalid mapping on line #{line_number}. Use slack_identifier=campfire_user."
          end

          mapping_key = normalize_mapping_key(slack_identifier)
          if mappings.key?(mapping_key)
            raise InvalidMappingsError, "Duplicate Slack mapping '#{slack_identifier}' on line #{line_number}."
          end

          mapped_user = find_user_by_mapping_identifier(campfire_identifier)
          unless mapped_user
            raise InvalidMappingsError, "Unknown Campfire user '#{campfire_identifier}' on line #{line_number}."
          end

          mappings[mapping_key] = mapped_user
        end

        mappings
      end
    end

    def normalize_mapping_key(value)
      value.to_s.strip.downcase
    end

    def find_local_user(slack_user)
      return unless slack_user.is_a?(Hash)

      emails = [
        slack_user.dig("profile", "email"),
        slack_user["email"]
      ].compact_blank

      names = [
        slack_user.dig("profile", "display_name"),
        slack_user.dig("profile", "real_name"),
        slack_user["real_name"],
        slack_user["name"]
      ].compact_blank

      emails.each do |email|
        user = users_by_email[email.downcase]
        return user if user
      end

      names.each do |name|
        user = users_by_name[name.downcase]
        return user if user
      end

      nil
    end

    def users_by_email
      @users_by_email ||= User.without_bots.where.not(email_address: nil).index_by { |user| user.email_address.downcase }
    end

    def users_by_name
      @users_by_name ||= User.without_bots.index_by { |user| user.name.downcase }
    end

    def users_by_id
      @users_by_id ||= User.without_bots.index_by { |user| user.id.to_s }
    end

    def find_user_by_mapping_identifier(identifier)
      normalized_identifier = normalize_mapping_key(identifier)

      users_by_id[normalized_identifier] ||
        users_by_email[normalized_identifier] ||
        users_by_name[normalized_identifier]
    end

    def import_bot
      @import_bot ||= User.active_bots.find_by(name: IMPORT_BOT_NAME) || User.create_bot!(name: IMPORT_BOT_NAME)
    end

    def message_entries_from(zip)
      zip.entries.select { |entry| entry.file? && entry.name.match?(MESSAGE_ENTRY_PATTERN) }.sort_by(&:name)
    end

    def find_or_create_room(channel_name)
      existing_room = Room.opens.find_by("LOWER(name) = ?", channel_name.downcase)
      return [ existing_room, false ] if existing_room

      [ Room.create_for({ name: channel_name, type: "Rooms::Open", creator: importer }, users: User.active), true ]
    end

    def channel_name_from(entry_name)
      entry_name.match(MESSAGE_ENTRY_PATTERN)&.named_captures&.fetch("channel", nil)
    end

    def parse_timestamp(timestamp)
      Time.zone.at(Float(timestamp))
    rescue ArgumentError, TypeError
      nil
    end

    def client_message_id_for(channel_name, timestamp)
      "slack:#{channel_name}:#{timestamp}"
    end

    def parse_optional_json_file(zip, name)
      entry = zip.find_entry(name)
      return [] unless entry

      parsed = parse_json_entry(entry)
      parsed.is_a?(Array) ? parsed : []
    end

    def load_channels_by_id(zip)
      channel_entries = parse_optional_json_file(zip, "channels.json") + parse_optional_json_file(zip, "groups.json")

      channel_entries.each_with_object({}) do |channel, result|
        next unless channel.is_a?(Hash) && channel["id"].present?
        result[channel["id"]] = channel["name"]
      end
    end

    def parse_json_entry(entry)
      JSON.parse(entry.get_input_stream.read)
    rescue JSON::ParserError
      raise InvalidArchiveError, "Slack export contains invalid JSON in #{entry.name}."
    end

    def display_name_for(slack_user)
      return unless slack_user.is_a?(Hash)

      [
        slack_user.dig("profile", "display_name"),
        slack_user.dig("profile", "real_name"),
        slack_user["real_name"],
        slack_user["name"]
      ].compact_blank.first
    end

    def normalize_text(text, channels_by_id:, users_by_slack_id:)
      CGI.unescapeHTML(text.to_s).gsub(/<([^>]+)>/) do
        normalize_token(Regexp.last_match(1), channels_by_id:, users_by_slack_id:)
      end
    end

    def normalize_token(token, channels_by_id:, users_by_slack_id:)
      case token
      when /\A@(?<user_id>[A-Z0-9]+)(?:\|(?<fallback>.+))?\z/
        user_name = display_name_for(users_by_slack_id[Regexp.last_match[:user_id]]) || Regexp.last_match[:fallback]
        user_name.present? ? "@#{user_name}" : "@unknown"
      when /\A#(?<channel_id>[A-Z0-9]+)(?:\|(?<fallback>.+))?\z/
        channel_name = channels_by_id[Regexp.last_match[:channel_id]] || Regexp.last_match[:fallback]
        channel_name.present? ? "##{channel_name}" : "#unknown"
      when /\A!(?<group>channel|everyone|here)\z/
        "@#{Regexp.last_match[:group]}"
      when /\A!subteam\^[^|]+\|(?<group>.+)\z/
        "@#{Regexp.last_match[:group]}"
      when /\A(?<url>mailto:[^|]+)\|(?<label>.+)\z/
        label_or_url(label: Regexp.last_match[:label], url: Regexp.last_match[:url].delete_prefix("mailto:"))
      when /\A(?<url>https?:\/\/[^|]+)(?:\|(?<label>.+))?\z/
        label_or_url(label: Regexp.last_match[:label], url: Regexp.last_match[:url])
      else
        token
      end
    end

    def label_or_url(label:, url:)
      return url if label.blank? || label == url
      "#{label} (#{url})"
    end

    def archive_path
      archive.respond_to?(:tempfile) ? archive.tempfile.path : archive.path
    end
end
