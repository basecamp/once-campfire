require "test_helper"

class WebPush::ConnectionsTest < ActiveSupport::TestCase
  include PushServiceTestHelper

  setup { @connections = WebPush::Connections.new }
  teardown { @connections.shutdown }

  test "a delivery to the same host and address reuses the open connection" do
    with_push_service do |server|
      2.times { |i| assert_kind_of Net::HTTPCreated, @connections.request(pinned_connection(server), push_request("/push/#{i}")) }

      assert_equal 1, server.connections
      assert_equal %w[ /push/0 /push/1 ], server.requests
    end
  end

  test "a delivery to another address never reuses a connection" do
    with_push_service do |server|
      @connections.request(pinned_connection(server), push_request)

      other = pinned_connection(server, "127.0.0.2")
      other.expects(:start)
      other.expects(:request).returns(:sent_to_the_other_address)
      assert_equal :sent_to_the_other_address, @connections.request(other, push_request)
      assert_equal 1, server.requests.size
    end
  end

  test "a connection the push service closed while idle is replaced, and the push sent once" do
    [ :fin, :close_notify ].each do |hang_up|
      with_push_service(hang_up_after_response: hang_up) do |server|
        @connections.request(pinned_connection(server), push_request("/push/0"))
        assert server.hung_up?

        assert_kind_of Net::HTTPCreated, @connections.request(pinned_connection(server), push_request("/push/1"))
        assert_equal 2, server.connections
        assert_equal %w[ /push/0 /push/1 ], server.requests
      end
    end
  end

  test "a certificate for another name is refused, and nothing is sent" do
    with_push_service(certificate: ->(_) { "other.test" }) do |server|
      assert_raises(OpenSSL::SSL::SSLError) { @connections.request(pinned_connection(server), push_request) }
      assert_empty server.requests
    end
  end

  test "a certificate for another name is refused when a dead connection is replaced too" do
    with_push_service(hang_up_after_response: :fin, certificate: ->(connection) { connection == 1 ? HOST : "other.test" }) do |server|
      @connections.request(pinned_connection(server), push_request)
      assert server.hung_up?

      assert_raises(OpenSSL::SSL::SSLError) { @connections.request(pinned_connection(server), push_request) }
      assert_equal 1, server.requests.size
    end
  end

  test "a push the service may have received is not sent again" do
    with_push_service(drop_request: ->(number) { number == 2 }) do |server|
      @connections.request(pinned_connection(server), push_request("/push/0"))

      error = assert_raises(WebPush::Connections::ConnectionLost) { @connections.request(pinned_connection(server), push_request("/push/1")) }
      assert_not_kind_of OpenSSL::OpenSSLError, error
      assert_equal %w[ /push/0 /push/1 ], server.requests
      assert_equal 1, server.connections
    end
  end

  test "only new, direct TLS connections pinned to an address are pooled" do
    with_push_service do |server|
      unpinned = Net::HTTP.new(HOST, server.port, nil).tap { it.use_ssl = true }
      proxied = Net::HTTP.new(HOST, server.port, "127.0.0.1", 3128).tap { it.ipaddr = IP; it.use_ssl = true }
      plain = pinned_connection(server).tap { it.use_ssl = false }
      started = pinned_connection(server).tap(&:start)

      [ unpinned, proxied, plain, started ].each do |http|
        assert_raises(ArgumentError) { @connections.request(http, push_request) }
      end
      assert_empty server.requests
    ensure
      started&.finish
    end
  end

  test "a forked process opens its own connections" do
    with_push_service do |server|
      @connections.request(pinned_connection(server), push_request)

      child = Process.pid + 1
      Process.stubs(:pid).returns(child)
      @connections.request(pinned_connection(server), push_request)
      assert_equal 2, server.connections
    end
  end

  test "a forked process shutting down leaves its parent's connections open" do
    with_push_service do |server|
      @connections.request(pinned_connection(server), push_request)

      child = Process.pid + 1
      Process.stubs(:pid).returns(child)
      @connections.shutdown
      assert_not server.hung_up?(within: 0.5)
    end
  end

  test "idle connections are closed after the keep-alive timeout and on shutdown" do
    connections = WebPush::Connections.new(keep_alive_timeout: 0)

    with_push_service do |server|
      other = Server.new
      connections.request(pinned_connection(server), push_request)
      connections.request(pinned_connection(other), push_request)
      assert server.hung_up?

      connections.shutdown
      assert other.hung_up?

      connections.request(pinned_connection(server), push_request)
      assert server.hung_up?
    ensure
      other&.stop
    end
  end
end
