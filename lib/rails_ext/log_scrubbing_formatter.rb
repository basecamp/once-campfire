# Bot requests carry the bot key as a URL path segment (/rooms/:room_id/:bot_key/...).
# config.filter_parameters redacts query and form parameters but never path segments,
# so the key would otherwise be written verbatim to the request log. Redact it wherever
# it appears in a formatted log line.
class LogScrubbingFormatter < ::Logger::Formatter
  BOT_KEY_IN_PATH = %r{(/rooms/\d+/)\d+-[A-Za-z0-9]+}

  def call(severity, time, progname, message)
    scrub(super)
  end

  private
    def scrub(line)
      line.gsub(BOT_KEY_IN_PATH, '\1[FILTERED]')
    end
end
