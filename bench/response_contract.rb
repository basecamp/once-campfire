require "json"
require "open3"
require "cgi"

# Independent seed SQL determines the required result window before any response is sampled.
class BenchmarkResponseContract
  def initialize(kind, database, labels)
    @kind = kind
    room = Integer(labels.fetch("rooms.watercooler"))
    user = labels.fetch("emails.david").gsub("'", "''")
    @ids = case kind
    when "room"
      query(database, "SELECT id FROM messages WHERE room_id=#{room} ORDER BY created_at DESC LIMIT 40").reverse.map { |row| row.fetch("id") }
    when "messages"
      before = Integer(labels.fetch("messages.busy_060"))
      query(database, "SELECT id FROM messages WHERE room_id=#{room} AND created_at<(SELECT created_at FROM messages WHERE id=#{before}) ORDER BY created_at DESC LIMIT 40").reverse.map { |row| row.fetch("id") }
    when "search"
      query(database, "SELECT m.id FROM message_search_index idx JOIN messages m ON m.id=idx.rowid JOIN memberships mm ON mm.room_id=m.room_id JOIN users u ON u.id=mm.user_id WHERE u.email_address='#{user}' AND idx.body MATCH 'coffee' ORDER BY m.id DESC LIMIT 100").reverse.map { |row| row.fetch("id") }
    when "sidebar"
      @names = query(database, "SELECT r.name FROM rooms r JOIN memberships mm ON mm.room_id=r.id JOIN users u ON u.id=mm.user_id WHERE u.email_address='#{user}' AND r.type='Rooms::Open' AND mm.involvement<>'invisible'").map { |row| CGI.escapeHTML(row.fetch("name")) }
      nil
    else
      raise "Unknown route contract #{kind}"
    end
  end

  def valid?(response)
    body = response.body.to_s
    return false unless response.code == "200" && response["content-type"].to_s.split(";").first == "text/html" &&
      [ nil, "identity" ].include?(response["content-encoding"]) && !body.empty? && body.dup.force_encoding("UTF-8").valid_encoding?
    return false if @kind != "messages" && !(body.lstrip.start_with?("<!DOCTYPE html>") && body.rstrip.end_with?("</html>"))
    return false if @ids && body.scan(/data-message-id="(\d+)"/).flatten.map(&:to_i) != @ids
    return false if @names && (!body.include?("shared_rooms") || @names.any? { |name| !body.include?(name) })
    true
  end

  private
    def query(database, sql)
      output, errors, status = Open3.capture3("sqlite3", "-readonly", "-json", database, sql)
      raise "Cannot read benchmark seed: #{errors}" unless status.success?
      JSON.parse(output)
    end
end
