require "pathname"

module CampfireBackup
  module MountIdentity
    MOUNTINFO_PATH = Pathname("/proc/self/mountinfo")
    MAX_MOUNTINFO_BYTES = 4 * 1024 * 1024

    class Error < RuntimeError; end

    Entry = Struct.new(
      :mount_id, :parent_id, :device, :root, :mount_point, :filesystem_type, :source,
      keyword_init: true
    ) do
      def covers?(path)
        path = Pathname(path).expand_path.to_s
        point = mount_point.to_s
        path == point || point == "/" || path.start_with?("#{point}/")
      end

      def source_identity
        [ device, root, filesystem_type ].freeze
      end

      def same_source_volume?(other)
        return false unless device == other.device && filesystem_type == other.filesystem_type

        left = Pathname(root).cleanpath.to_s
        right = Pathname(other.root).cleanpath.to_s
        left == right || left == "/" || right == "/" ||
          left.start_with?("#{right}/") || right.start_with?("#{left}/")
      end
    end

    class << self
      def for_path(path, mountinfo_path: MOUNTINFO_PATH)
        path = Pathname(path).realpath
        entries = parse(read_mountinfo(mountinfo_path))
        matches = entries.select { _1.covers?(path) }
        raise Error, "No mount identity covers #{path}" if matches.empty?

        depth = matches.map { Pathname(_1.mount_point).each_filename.count }.max
        deepest = matches.select { Pathname(_1.mount_point).each_filename.count == depth }
        unless deepest.one?
          raise Error, "Mount identity for #{path} is ambiguous"
        end
        deepest.first
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP => error
        raise Error, "Mount identity is unavailable: #{error.message}"
      end

      def parse(source)
        raise Error, "Mount identity data is empty" if source.empty?

        entries = source.lines.map.with_index(1) do |line, line_number|
          parse_line line.chomp, line_number
        end
        unless entries.map(&:mount_id).uniq.size == entries.size
          raise Error, "Mount identity data contains duplicate mount IDs"
        end
        entries.freeze
      end

      private
        def read_mountinfo(path)
          File.open(path, File::RDONLY) do |file|
            source = file.read(MAX_MOUNTINFO_BYTES + 1)
            if source.bytesize > MAX_MOUNTINFO_BYTES
              raise Error, "Mount identity data exceeds its safe size limit"
            end
            source
          end
        end

        def parse_line(line, line_number)
          sections = line.split(" - ", -1)
          unless sections.length == 2
            raise Error, "Mount identity line #{line_number} is malformed"
          end
          mount = sections.fetch(0).split
          filesystem = sections.fetch(1).split
          unless mount.length >= 6 && filesystem.length >= 3 &&
              mount.fetch(0).match?(/\A[1-9]\d*\z/) &&
              mount.fetch(1).match?(/\A[1-9]\d*\z/) &&
              mount.fetch(2).match?(/\A\d+:\d+\z/)
            raise Error, "Mount identity line #{line_number} is malformed"
          end

          root = decode_field(mount.fetch(3), line_number)
          mount_point = decode_field(mount.fetch(4), line_number)
          filesystem_type = decode_field(filesystem.fetch(0), line_number)
          source = decode_field(filesystem.fetch(1), line_number)
          unless root.start_with?("/") && mount_point.start_with?("/") &&
              !filesystem_type.empty? && !source.empty?
            raise Error, "Mount identity line #{line_number} is malformed"
          end

          Entry.new(
            mount_id: Integer(mount.fetch(0), 10),
            parent_id: Integer(mount.fetch(1), 10),
            device: mount.fetch(2).freeze,
            root: Pathname(root).cleanpath.to_s.freeze,
            mount_point: Pathname(mount_point).cleanpath.to_s.freeze,
            filesystem_type: filesystem_type.freeze,
            source: source.freeze
          ).freeze
        rescue ArgumentError
          raise Error, "Mount identity line #{line_number} is malformed"
        end

        def decode_field(value, line_number)
          decoded = value.gsub(/\\(040|011|012|134)/) do
            { "040" => " ", "011" => "\t", "012" => "\n", "134" => "\\" }.fetch(Regexp.last_match(1))
          end
          if decoded.include?("\\") || decoded.include?("\0")
            raise Error, "Mount identity line #{line_number} has invalid escaping"
          end
          decoded
        end
    end
  end
end
