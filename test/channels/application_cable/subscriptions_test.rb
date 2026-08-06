require "test_helper"
require "action_cable/channel/test_case"
require "timeout"

class ApplicationCable::SubscriptionsTest < ActiveSupport::TestCase
  class ConnectionStub < ActionCable::Channel::ConnectionStub
    def initialize(maximum:)
      super()
      @subscriptions = ApplicationCable::Subscriptions.new(self, maximum:)
    end

    delegate :worker_pool, to: :server
  end

  class BackendAddBarrier < Hash
    def initialize(identifier, entered:, release:)
      super()
      self["identifier"] = identifier
      @entered = entered
      @release = release
      @identifier_reads = 0
    end

    def [](key)
      value = super
      if key == "identifier" && (@identifier_reads += 1) == 2
        @entered << true
        @release.pop
      end
      value
    end
  end

  setup do
    @connection = ConnectionStub.new(maximum: 3)
  end

  teardown do
    @connection.subscriptions.unsubscribe_from_all
  end

  test "connection installs bounded application subscriptions" do
    env = Rack::MockRequest.env_for "/cable", "HTTP_HOST" => "localhost"
    connection = ApplicationCable::Connection.new(ActionCable.server, env)

    assert_instance_of ApplicationCable::Subscriptions, connection.subscriptions
  end

  test "nonce and signature variants share one verified Turbo stream subscription" do
    @connection.server.event_loop.stubs(:post)
    stream_name = "room:bounded-stream"
    first_identifier = turbo_identifier(
      Turbo.signed_stream_verifier.generate(stream_name), nonce: "first"
    )
    second_identifier = turbo_identifier(
      Turbo.signed_stream_verifier.generate(stream_name, expires_in: 1.hour), nonce: "second"
    )

    subscribe first_identifier
    subscribe second_identifier

    assert_equal [ first_identifier ], @connection.subscriptions.identifiers
    assert_equal 2, @connection.subscriptions.client_subscription_count
    assert_equal [ first_identifier, second_identifier ].sort,
      @connection.subscriptions.delivery_identifiers_for(first_identifier).sort
    assert_not confirmed?(second_identifier)

    transmissions = cable_connection.send(
      :transmissions_for,
      identifier: first_identifier,
      type: ActionCable::INTERNAL[:message_types][:confirmation]
    )
    assert_equal [ first_identifier, second_identifier ].sort,
      transmissions.pluck(:identifier).sort

    broadcast_transmissions = cable_connection.send(
      :transmissions_for, identifier: first_identifier, message: "broadcast"
    )
    assert_equal [ first_identifier, second_identifier ].sort,
      broadcast_transmissions.pluck(:identifier).sort

    third_identifier = turbo_identifier(
      Turbo.signed_stream_verifier.generate(stream_name), nonce: "third"
    )
    subscribe third_identifier
    assert confirmed?(third_identifier)

    unsubscribe first_identifier
    assert_equal [ first_identifier ], @connection.subscriptions.identifiers
    assert_equal [ second_identifier, third_identifier ].sort,
      @connection.subscriptions.delivery_identifiers_for(first_identifier).sort
  end

  test "an alias is not confirmed when the underlying stream never becomes ready" do
    @connection.server.event_loop.stubs(:post)
    stream_name = "room:failing-stream"
    first_identifier = turbo_identifier(
      Turbo.signed_stream_verifier.generate(stream_name), nonce: "first"
    )
    second_identifier = turbo_identifier(
      Turbo.signed_stream_verifier.generate(stream_name, expires_in: 1.hour), nonce: "second"
    )

    subscribe first_identifier
    subscribe second_identifier

    assert_equal [ first_identifier ], @connection.subscriptions.identifiers
    assert_not confirmed?(first_identifier)
    assert_not confirmed?(second_identifier)
  end

  test "rejects subscriptions beyond the per-connection cap" do
    identifiers = 4.times.map do |nonce|
      { channel: "HeartbeatChannel", nonce: }.to_json
    end

    identifiers.each { subscribe(_1) }

    assert_equal identifiers.first(3), @connection.subscriptions.identifiers
    assert_equal 3, @connection.subscriptions.client_subscription_count
    assert_equal identifiers.last, @connection.transmissions.last["identifier"]
    assert_equal ActionCable::INTERNAL[:message_types][:rejection],
      @connection.transmissions.last["type"]
  end

  test "unsubscribe before backend add cannot orphan an uncounted subscription" do
    identifier = { channel: "HeartbeatChannel", nonce: "raced" }.to_json

    subscribe_result, unsubscribe_result = race_unsubscribe_before_backend_add(identifier)

    assert_not_kind_of StandardError, subscribe_result
    assert_not_kind_of StandardError, unsubscribe_result
    assert_empty @connection.subscriptions.identifiers
    assert_equal 0, @connection.subscriptions.client_subscription_count
  end

  test "repeated unsubscribe before backend add cannot bypass the cap" do
    @connection = ConnectionStub.new(maximum: 1)
    results = 3.times.flat_map do |nonce|
      identifier = { channel: "HeartbeatChannel", nonce: "raced-#{nonce}" }.to_json
      race_unsubscribe_before_backend_add(identifier)
    end
    active_identifier = { channel: "HeartbeatChannel", nonce: "active" }.to_json

    subscribe active_identifier

    assert_equal [ active_identifier ], @connection.subscriptions.identifiers
    assert_equal 1, @connection.subscriptions.client_subscription_count
    assert_empty results.grep(StandardError)
  end

  test "confirmation and delivery multiplexing do not wait for a backend transition" do
    @connection.server.event_loop.stubs(:post)
    stream_name = "room:transition-independent-multiplexing"
    first_identifier = turbo_identifier(
      Turbo.signed_stream_verifier.generate(stream_name), nonce: "first"
    )
    second_identifier = turbo_identifier(
      Turbo.signed_stream_verifier.generate(stream_name, expires_in: 1.hour), nonce: "second"
    )
    subscribe first_identifier
    subscribe second_identifier
    transition, release = pause_before_backend_add(
      { channel: "HeartbeatChannel", nonce: "paused" }.to_json
    )

    multiplexing = Thread.new do
      confirmation = cable_connection.send(
        :transmissions_for,
        identifier: first_identifier,
        type: ActionCable::INTERNAL[:message_types][:confirmation]
      )
      delivery = cable_connection.send(
        :transmissions_for, identifier: first_identifier, message: "broadcast"
      )
      [ confirmation, delivery ]
    end
    confirmation, delivery = Timeout.timeout(5) { multiplexing.value }
    release << true
    transition_result = Timeout.timeout(5) { transition.value }

    assert_equal [ first_identifier, second_identifier ].sort,
      confirmation.pluck(:identifier).sort
    assert_equal [ first_identifier, second_identifier ].sort,
      delivery.pluck(:identifier).sort
    assert_not_kind_of StandardError, transition_result
  ensure
    release << true if release
    transition&.join(5)
    multiplexing&.join(5)
  end

  private
    def turbo_identifier(signed_stream_name, nonce:)
      { channel: "Turbo::StreamsChannel", signed_stream_name:, nonce: }.to_json
    end

    def cable_connection
      ApplicationCable::Connection.allocate.tap do |connection|
        connection.instance_variable_set(:@subscriptions, @connection.subscriptions)
      end
    end

    def confirmed?(identifier)
      @connection.transmissions.any? do |transmission|
        transmission["identifier"] == identifier &&
          transmission["type"] == ActionCable::INTERNAL[:message_types][:confirmation]
      end
    end

    def subscribe(identifier)
      @connection.subscriptions.execute_command(
        "command" => "subscribe", "identifier" => identifier
      )
    end

    def unsubscribe(identifier)
      @connection.subscriptions.execute_command(
        "command" => "unsubscribe", "identifier" => identifier
      )
    end

    def pause_before_backend_add(identifier)
      entered = Queue.new
      release = Queue.new
      data = BackendAddBarrier.new(identifier, entered:, release:)
      transition = capturing_thread { @connection.subscriptions.add(data) }
      Timeout.timeout(5) { entered.pop }
      [ transition, release ]
    end

    def race_unsubscribe_before_backend_add(identifier)
      transition, release = pause_before_backend_add(identifier)
      unsubscribe_started = Queue.new
      removal = capturing_thread do
        unsubscribe_started << true
        @connection.subscriptions.remove("identifier" => identifier)
      end
      Timeout.timeout(5) do
        unsubscribe_started.pop
        Thread.pass while removal.alive? && removal.status != "sleep"
      end
      release << true
      [ transition.value, removal.value ]
    ensure
      release << true if release
      transition&.join(5)
      removal&.join(5)
    end

    def capturing_thread(&block)
      Thread.new do
        block.call
      rescue StandardError => error
        error
      end
    end
end
