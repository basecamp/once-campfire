require "fileutils"
require "pathname"
require "sqlite3"
require "tmpdir"
require_relative "upgrade_recovery_guard"

module CampfireBackup
  module SchemaVerifier
    INTERNAL_TABLES = %w[ ar_internal_metadata schema_migrations ].freeze

    class << self
      def verify!(database_path, schema_version:)
        load_application!
        database_path = Pathname(database_path)
        versions = migration_versions
        schema_version = Integer(schema_version)
        raise "Backup schema is not supplied by this image" unless schema_version.in?(versions)

        verify_migration_set! database_path, versions.select { _1 <= schema_version }
        original_config = ActiveRecord::Base.connection_db_config
        migration_verbosity = ActiveRecord::Migration.verbose
        ActiveRecord::Migration.verbose = false

        Dir.mktmpdir("campfire-schema-verification") do |directory|
          upgraded_path = Pathname(directory).join("upgraded.sqlite3")
          migrated_path = Pathname(directory).join("migrated.sqlite3")
          loaded_path = Pathname(directory).join("loaded.sqlite3")
          FileUtils.copy_file database_path, upgraded_path
          migrate! upgraded_path
          migrate! migrated_path
          load_schema! loaded_path

          actual = schema_signature(upgraded_path)
          expected = schema_signature(migrated_path)
          loaded = schema_signature(loaded_path)
          unless expected == loaded
            raise "Application migrations and db/schema.rb do not match: #{first_difference(expected, loaded)}"
          end
          unless actual == expected
            raise "Backup database does not match the application schema contract: #{first_difference(actual, expected)}"
          end
        end
      ensure
        ActiveRecord::Migration.verbose = migration_verbosity unless migration_verbosity.nil?
        ActiveRecord::Base.establish_connection(original_config) if original_config
      end

      private
        def migration_versions
          Rails.root.join("db/migrate").children.filter_map do |path|
            path.basename.to_s.split("_", 2).first.to_i if path.extname == ".rb"
          end.sort
        end

        def verify_migration_set!(database_path, expected_versions)
          database = SQLite3::Database.new(database_path.to_s, readonly: true)
          actual = database.execute("SELECT version FROM schema_migrations").flatten.map(&:to_i).sort
          raise "Backup database migration set is incomplete or unknown" unless actual == expected_versions
        ensure
          database&.close
        end

        def migrate!(database_path)
          CampfireBackup::UpgradeRecoveryGuard.with_schema_verifier_target(database_path) do
            ActiveRecord::Base.establish_connection(
              adapter: "sqlite3", database: database_path.to_s, timeout: 5000,
              default_transaction_mode: "immediate"
            )
            ActiveRecord::Base.connection_pool.migration_context.up
          ensure
            ActiveRecord::Base.connection.disconnect!
          end
        end

        def load_schema!(database_path)
          CampfireBackup::UpgradeRecoveryGuard.with_schema_verifier_target(database_path) do
            ActiveRecord::Base.establish_connection(
              adapter: "sqlite3", database: database_path.to_s, timeout: 5000,
              default_transaction_mode: "immediate"
            )
            load Rails.root.join("db/schema.rb")
          ensure
            ActiveRecord::Base.connection.disconnect!
          end
        end

        def schema_signature(database_path)
          database = SQLite3::Database.new(database_path.to_s, readonly: true)
          objects = database.execute(<<~SQL).to_h { |type, name, table, sql| [ name, [ type, table, sql ] ] }
            SELECT type, name, tbl_name, sql
            FROM sqlite_schema
            WHERE name NOT LIKE 'sqlite_%'
              AND name NOT IN ('#{INTERNAL_TABLES.join("','")}')
            ORDER BY type, name
          SQL

          tables = objects.filter_map do |name, (type, _, sql)|
            next unless type == "table"

            [ name, table_signature(database, name, sql) ]
          end.to_h
          indexes = tables.keys.flat_map { index_signatures(database, _1) }.sort.to_h
          other = objects.filter_map do |name, (type, table, sql)|
            [ name, [ type, table, normalize_sql(sql) ] ] if type.in?(%w[ trigger view ])
          end.to_h
          { tables:, indexes:, other: }
        ensure
          database&.close
        end

        def first_difference(actual, expected)
          %i[ tables indexes other ].each do |kind|
            actual_names = actual.fetch(kind).keys
            expected_names = expected.fetch(kind).keys
            missing = expected_names - actual_names
            extra = actual_names - expected_names
            return "missing #{kind.to_s.singularize} #{missing.first}" if missing.any?
            return "unexpected #{kind.to_s.singularize} #{extra.first}" if extra.any?

            actual_names.each do |name|
              return "#{kind.to_s.singularize} #{name} differs" unless actual.dig(kind, name) == expected.dig(kind, name)
            end
          end
        end

        def table_signature(database, table, sql)
          columns = database.execute("PRAGMA table_xinfo(#{quote_identifier(table)})").map do |row|
            _, name, type, not_null, default, primary_key, hidden = row
            [ name, type.to_s.downcase, not_null, normalize_sql(default), primary_key, hidden ]
          end.sort
          foreign_keys = database.execute("PRAGMA foreign_key_list(#{quote_identifier(table)})")
            .map { _1.drop(2) }.sort
          virtual = sql.to_s.match?(/\ACREATE\s+VIRTUAL\s+TABLE/i)
          table_kind = virtual ? normalize_sql(sql) : "table"
          {
            kind: table_kind,
            columns:,
            autoincrement: virtual ? [] : autoincrement_columns(sql, columns.map(&:first)),
            collations: virtual ? [] : column_collations(sql, columns.map(&:first)),
            foreign_keys:,
            checks: check_expressions(sql).sort,
            options: virtual ? {} : table_options(database, table)
          }
        end

        def index_signatures(database, table)
          database.execute("PRAGMA index_list(#{quote_identifier(table)})").map do |list_row|
            name = list_row.fetch(1)
            sql = database.get_first_value(
              "SELECT sql FROM sqlite_schema WHERE type = 'index' AND name = ?", name
            )
            [ name, index_signature(database, name, sql, list_row) ]
          end
        end

        def index_signature(database, name, sql, list_row)
          columns = database.execute("PRAGMA index_xinfo(#{quote_identifier(name)})").map do |row|
            row.values_at(0, 2, 3, 4, 5)
          end.sort
          source = strip_sql_comments(sql)
          {
            unique: list_row&.fetch(2), origin: list_row&.fetch(3), partial: list_row&.fetch(4),
            columns:, where: normalize_sql(source[/\bWHERE\b(.+)\z/im, 1])
          }
        end

        def column_collations(sql, column_names)
          definitions = table_definitions(sql)
          collations = definitions.filter_map do |definition|
            identifier, remainder = leading_identifier(definition)
            column = column_names.find { _1.casecmp?(identifier.to_s) }
            next unless column

            offset = top_level_keyword_end(remainder, "COLLATE")
            collation, = leading_identifier(remainder[offset..]) if offset
            raise "Backup schema contains an invalid column collation" if offset && collation.nil?

            [ column, collation&.downcase || "binary" ]
          end.to_h
          unless collations.keys.sort == column_names.sort
            raise "Backup schema contains an invalid table definition"
          end

          collations.sort
        end

        def autoincrement_columns(sql, column_names)
          table_definitions(sql).filter_map do |definition|
            identifier, remainder = leading_identifier(definition)
            column = column_names.find { _1.casecmp?(identifier.to_s) }
            column if column && top_level_keyword_end(remainder, "AUTOINCREMENT")
          end.sort
        end

        def table_options(database, table)
          _, _, _, _, without_rowid, strict = database.execute(
            "PRAGMA table_list(#{quote_identifier(table)})"
          ).fetch(0)
          {
            strict: strict == 1,
            without_rowid: without_rowid == 1
          }
        end

        def table_definitions(sql)
          source = strip_sql_comments(sql)
          opening = source.index("(")
          raise "Backup schema contains an invalid table definition" unless opening

          definitions = []
          start = opening + 1
          depth = 1
          quote = nil
          index = start
          while index < source.length
            character = source[index]
            if quote
              closing = quote == "[" ? "]" : quote
              if character == closing
                if source[index + 1] == closing
                  index += 1
                else
                  quote = nil
                end
              end
            elsif character.in?([ "'", '"', "`", "[" ])
              quote = character
            elsif character == "("
              depth += 1
            elsif character == ")"
              depth -= 1
              if depth.zero?
                definitions << source[start...index]
                return definitions
              end
            elsif character == "," && depth == 1
              definitions << source[start...index]
              start = index + 1
            end
            index += 1
          end

          raise "Backup schema contains an invalid table definition"
        end

        def leading_identifier(source)
          source = source.to_s.lstrip
          return [ nil, source ] if source.empty?

          opening = source[0]
          if opening.in?([ "'", '"', "`", "[" ])
            closing = opening == "[" ? "]" : opening
            identifier = +""
            index = 1
            while index < source.length
              character = source[index]
              if character == closing
                if source[index + 1] == closing
                  identifier << closing
                  index += 2
                  next
                end
                return [ identifier, source[(index + 1)..] ]
              end
              identifier << character
              index += 1
            end
            return [ nil, source ]
          end

          match = source.match(/\A[^\s,(]+/)
          [ match&.[](0), match ? source[match.end(0)..] : source ]
        end

        def top_level_keyword_end(source, keyword)
          source = source.to_s
          depth = 0
          quote = nil
          index = 0
          while index < source.length
            character = source[index]
            if quote
              closing = quote == "[" ? "]" : quote
              if character == closing
                if source[index + 1] == closing
                  index += 1
                else
                  quote = nil
                end
              end
            elsif character.in?([ "'", '"', "`", "[" ])
              quote = character
            elsif character == "("
              depth += 1
            elsif character == ")"
              depth -= 1
            elsif depth.zero? && source[index, keyword.length]&.casecmp?(keyword)
              before = index.zero? ? nil : source[index - 1]
              after = source[index + keyword.length]
              unless before&.match?(/[[:alnum:]_]/) || after&.match?(/[[:alnum:]_]/)
                return index + keyword.length
              end
            end
            index += 1
          end
        end

        def check_expressions(sql)
          source = strip_sql_comments(sql)
          expressions = []
          offset = 0
          while match = source.match(/\bCHECK\s*\(/i, offset)
            start = match.end(0)
            depth = 1
            quote = nil
            index = start
            while index < source.length && depth.positive?
              character = source[index]
              if quote
                closing = quote == "[" ? "]" : quote
                if character == closing
                  if source[index + 1] == closing
                    index += 1
                  else
                    quote = nil
                  end
                end
              elsif character.in?([ "'", '"', "`", "[" ])
                quote = character
              elsif character == "("
                depth += 1
              elsif character == ")"
                depth -= 1
              end
              index += 1
            end
            raise "Backup schema contains an invalid check constraint" unless depth.zero?

            expressions << normalize_sql(source[start...(index - 1)])
            offset = index
          end
          expressions
        end

        def normalize_sql(sql)
          source = strip_sql_comments(sql)
          normalized = +""
          in_string = false
          index = 0
          while index < source.length
            character = source[index]
            if in_string
              normalized << character
              if character == "'"
                if source[index + 1] == "'"
                  normalized << source[index + 1]
                  index += 1
                else
                  in_string = false
                end
              end
            elsif character == "'"
              in_string = true
              normalized << character
            elsif character.match?(/\s/) || character.in?([ '"', "`", "[", "]" ])
              nil
            else
              normalized << character.downcase
            end
            index += 1
          end
          normalized.presence
        end

        def strip_sql_comments(sql)
          source = sql.to_s
          stripped = +""
          quote = nil
          index = 0
          while index < source.length
            character = source[index]
            if quote
              stripped << character
              closing = quote == "[" ? "]" : quote
              if character == closing
                if source[index + 1] == closing
                  stripped << closing
                  index += 1
                else
                  quote = nil
                end
              end
            elsif character.in?([ "'", '"', "`", "[" ])
              quote = character
              stripped << character
            elsif source[index, 2] == "--"
              stripped << " "
              index += 1 until index + 1 >= source.length || source[index + 1].in?([ "\n", "\r" ])
            elsif source[index, 2] == "/*"
              stripped << " "
              closing = source.index("*/", index + 2)
              index = closing ? closing + 1 : source.length
            else
              stripped << character
            end
            index += 1
          end
          stripped
        end

        def quote_identifier(value)
          %Q("#{value.to_s.gsub('"', '""')}")
        end

        def load_application!
          require File.expand_path("../../config/environment", __dir__) unless defined?(Rails.application)
        end
    end
  end
end
