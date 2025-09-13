require 'json'
require 'zip'

module Imports
  module Slack
    class ExportReader
      attr_reader :path

      def initialize(path)
        @path = Pathname.new(path)
      end

      def users
        @users ||= read_json_file("users.json")
      end

      def channels
        @channels ||= read_json_file("channels.json")
      end

      def messages_for_channel(channel_id)
        return [] unless channel_id

        channel_dir = path.join(channel_id)
        return [] unless channel_dir.exist?

        message_files = channel_dir.glob("*.json").sort
        message_files.flat_map do |file|
          read_json_file(file.relative_path_from(path))
        end
      end

      def all_channels_with_messages
        channels.map do |channel|
          messages = messages_for_channel(channel["id"])
          channel.merge("messages" => messages)
        end
      end

      private

      def read_json_file(filename)
        file_path = path.join(filename)
        return [] unless file_path.exist?

        JSON.parse(file_path.read)
      rescue JSON::ParserError => e
        Rails.logger.warn "Failed to parse JSON file #{filename}: #{e.message}"
        []
      end
    end
  end
end