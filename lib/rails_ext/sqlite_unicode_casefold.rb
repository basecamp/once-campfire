# SQLite only knows the case of ASCII letters, in LIKE as in LOWER(), so "иг" doesn't match "Игорь". Every connection
# gets a unicode_casefold() function that applies Ruby's full Unicode case folding instead, to compare text without
# regard to case in any script. Folding also matches "strasse" to "Straße", which lowercasing wouldn't.
module SqliteUnicodeCasefold
  FLAGS = SQLite3::Constants::TextRep::UTF8 | SQLite3::Constants::TextRep::DETERMINISTIC

  private
    def configure_connection
      super

      # Malformed text would make downcase raise and fail the whole query, so it's scrubbed first.
      @raw_connection.define_function_with_flags("unicode_casefold", FLAGS) { |text| text&.scrub&.downcase(:fold) }
    end
end

ActiveSupport.on_load(:active_record_sqlite3adapter) { prepend SqliteUnicodeCasefold }
