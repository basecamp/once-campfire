require "minitest/autorun"
require "fileutils"
require "socket"
require "sqlite3"
require "tmpdir"
require_relative "http_client"
require_relative "response_contract"

class BenchmarkHTTPClientTest < Minitest::Test
  def setup
    @directory = Dir.mktmpdir("campfire-benchmark-test")
    database = File.join(@directory, "seed.sqlite3")
    SQLite3::Database.new(database).tap do |db|
      db.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY, room_id INTEGER, created_at TEXT)")
      db.execute("INSERT INTO messages VALUES (42, 1, '2026-10-01'), (43, 1, '2026-10-02')")
      db.close
    end
    @contract = BenchmarkResponseContract.new("room", database, "rooms.watercooler" => 1, "emails.david" => "david@example.com")
    @body = '<!DOCTYPE html><html><article data-message-id="42">coffee</article><article data-message-id="43">meeting</article></html>'
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_seeded_contract_rejects_error_pages_truncation_wrong_windows_and_encoding
    assert @contract.valid?(response(@body))
    refute @contract.valid?(response("Something went wrong"))
    refute @contract.valid?(response(@body.delete_suffix("</html>")))
    refute @contract.valid?(response(@body.sub('data-message-id="42"', 'data-message-id="99"')))
    refute @contract.valid?(response(@body, "text/plain"))
    refute @contract.valid?(response(@body + "\xFF".b))
    refute @contract.valid?(response(@body, "text/html", "500"))
  end

  def test_intermittent_200_error_page_rejects_the_loaded_run
    server = TCPServer.new("127.0.0.1", 0)
    worker = Thread.new do
      loop do
        socket = server.accept
        count = 0
        while socket.gets
          while (line = socket.gets) && line != "\r\n"
          end
          body = count % 8 == 0 ? "Something went wrong" : @body
          count += 1
          socket.write("HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}")
        end
        socket.close
      end
    rescue IOError, SystemCallError
      nil
    end
    client = BenchmarkHTTPClient.new("http://127.0.0.1:#{server.addr[1]}")
    error = assert_raises(RuntimeError) { client.measure("/rooms/1", "", concurrency: 1, duration: 0.1, contract: @contract) }
    assert_match(/HTTP statuses \{"200"\s*=>\s*\d+\}, 0 transport errors, [1-9]\d* invalid bodies/, error.message)
  ensure
    server&.close
    worker&.kill
    worker&.join
  end

  private
    def response(body, type = "text/html", status = "200")
      Net::HTTPResponse.new("1.1", status, "OK").tap do |result|
        result["content-type"] = type
        result.instance_variable_set(:@body, body)
        result.instance_variable_set(:@read, true)
      end
    end
end
