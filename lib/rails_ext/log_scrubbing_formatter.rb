# Legacy bot requests carry the key in the path (/rooms/:room_id/:bot_key/...).
# Prefer /rooms/:id/bot/... with X-Campfire-Bot-Key; this still redacts the old form.
# config.filter_parameters covers query/form params but never path segments.
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
