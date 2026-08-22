require "test_helper"

class MembershipTest < ActiveSupport::TestCase
  setup do
    @membership = memberships(:david_watercooler)
  end

  test "connected and disconnected scopes follow fresh presence" do
    presence = @membership.present
    assert Membership.connected.exists?(@membership.id)
    assert_not Membership.disconnected.exists?(@membership.id)

    @membership.absent presence
    assert_not Membership.connected.exists?(@membership.id)
    assert Membership.disconnected.exists?(@membership.id)
  end

  test "presence expires after the connection TTL" do
    @membership.present

    travel_to Membership::Connectable::CONNECTION_TTL.from_now + 1

    assert_not @membership.reload.connected?
    assert Membership.disconnected.exists?(@membership.id)
  end

  test "separate connection tokens remain independently present" do
    first = @membership.present
    second = @membership.present

    assert_equal 2, @membership.reload.presence_tokens.size
    assert @membership.absent(first)
    assert @membership.reload.connected?
    assert_equal [ second.token ], @membership.presence_tokens.keys
  end

  test "duplicate absence cannot consume a newer connection" do
    stale = @membership.present
    current = @membership.present(replacing: stale)

    assert_not @membership.absent(stale)
    assert @membership.reload.connected?
    assert_equal [ current.token ], @membership.presence_tokens.keys
  end

  test "stale refresh cannot resurrect an absent token" do
    stale = @membership.present
    @membership.absent stale
    current = @membership.present

    assert_not @membership.refresh_presence(stale)
    refreshed = @membership.refresh_presence(current)
    assert refreshed
    assert_not_equal current, refreshed
    assert_not @membership.absent(current)
    assert_equal [ refreshed.token ], @membership.reload.presence_tokens.keys
  end

  test "refresh extends only the matching connection" do
    presence = @membership.present
    travel_to Membership::Connectable::CONNECTION_TTL.from_now - 1.second

    refreshed = @membership.refresh_presence(presence)
    assert refreshed
    assert_not_equal presence, refreshed

    travel Membership::Connectable::CONNECTION_TTL - 1.second
    assert @membership.reload.connected?
  end

  test "refresh replaces an expired token without allowing stale absence" do
    expired = @membership.present
    travel Membership::Connectable::CONNECTION_TTL + 1.second

    refreshed = @membership.refresh_presence(expired)

    assert refreshed
    assert_not_equal expired, refreshed
    assert @membership.reload.connected?
    assert_not @membership.absent(expired)
    assert_equal [ refreshed.token ], @membership.reload.presence_tokens.keys
  end

  test "disconnect all leaves each live token recoverable exactly once" do
    first = @membership.present
    second = @membership.present

    Membership.disconnect_all

    assert_not @membership.reload.connected?
    first_replacement = @membership.refresh_presence(first)
    assert first_replacement
    assert @membership.reload.connected?
    assert_not @membership.absent(first)

    second_replacement = @membership.refresh_presence(second)
    assert second_replacement
    assert_equal [ first_replacement.token, second_replacement.token ].sort,
      @membership.reload.presence_tokens.keys.sort
  end

  test "stale absence consumes reset recovery without restoring connection state" do
    stale = @membership.present
    Membership.disconnect_all

    assert @membership.reload.absent(stale)
    assert_not @membership.reload.connected?
    assert_not @membership.refresh_presence(stale)
    assert_empty @membership.reload.presence_tokens
  end

  test "presence tokens are bounded" do
    presences = Array.new(Membership::Connectable::MAXIMUM_PRESENCE_TOKENS) { @membership.present }

    assert presences.all?
    assert_nil @membership.present
    assert_equal Membership::Connectable::MAXIMUM_PRESENCE_TOKENS, @membership.reload.presence_tokens.size
  end

  test "replacing a presence remains possible at the token limit" do
    presences = Array.new(Membership::Connectable::MAXIMUM_PRESENCE_TOKENS) { @membership.present }

    replacement = @membership.present(replacing: presences.first)

    assert replacement
    assert_not_includes @membership.reload.presence_tokens, presences.first.token
    assert_equal Membership::Connectable::MAXIMUM_PRESENCE_TOKENS, @membership.presence_tokens.size
  end

  test "expired tokens are removed before enforcing the token limit" do
    Membership::Connectable::MAXIMUM_PRESENCE_TOKENS.times { @membership.present }
    travel Membership::Connectable::CONNECTION_TTL + 1.second

    presence = @membership.present

    assert presence
    assert_equal [ presence.token ], @membership.reload.presence_tokens.keys
  end

  test "presence tokens are capped without evicting live connections" do
    presences = Membership::Connectable::MAXIMUM_PRESENCE_TOKENS.times.map { @membership.present }

    assert_not @membership.present
    assert_equal Membership::Connectable::MAXIMUM_PRESENCE_TOKENS, @membership.reload.presence_tokens.size
    assert_equal presences.map(&:token).sort, @membership.presence_tokens.keys.sort
  end

  test "a live presence can be safely replaced at the token cap" do
    presences = Membership::Connectable::MAXIMUM_PRESENCE_TOKENS.times.map { @membership.present }

    replacement = @membership.present(replacing: presences.first)

    assert replacement
    assert_equal Membership::Connectable::MAXIMUM_PRESENCE_TOKENS, @membership.reload.presence_tokens.size
    assert_not_includes @membership.presence_tokens.keys, presences.first.token
    assert_includes @membership.presence_tokens.keys, replacement.token
  end

  test "expired tokens are pruned before enforcing the token cap" do
    Membership::Connectable::MAXIMUM_PRESENCE_TOKENS.times { @membership.present }
    travel Membership::Connectable::CONNECTION_TTL + 1.second

    replacement = @membership.present

    assert replacement
    assert_equal [ replacement.token ], @membership.reload.presence_tokens.keys
  end

  test "removing a membership resets the user's connections" do
    @membership.user.expects(:disconnect_remote_connections).with(reconnect: true)

    @membership.destroy
  end

  test "removing a membership advances the user's authorization generation" do
    user = @membership.user
    user.stubs(:disconnect_remote_connections)

    assert_difference -> { user.reload.authorization_generation }, 1 do
      @membership.destroy!
    end
  end

  test "failure to advance authorization rolls back membership removal" do
    @membership.user.stubs(:increment!).raises(ActiveRecord::StatementInvalid, "generation update failed")

    assert_raises(ActiveRecord::StatementInvalid) { @membership.destroy! }

    assert Membership.exists?(@membership.id)
  end

  test "changing involvement advances the user's authorization generation" do
    user = @membership.user
    user.stubs(:disconnect_remote_connections)

    assert_difference -> { user.reload.authorization_generation }, 1 do
      @membership.update!(involvement: :nothing)
    end
  end
end

class MembershipConnectableConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @membership = memberships(:david_watercooler)
    @membership.update_columns(presence_tokens: {}, connected_at: nil, presence_generation: 0)
  end

  test "concurrent connections retain every token" do
    presences = run_concurrently(8) { Membership.find(@membership.id).present }

    assert_equal 8, presences.map(&:token).uniq.size
    assert_equal 8, @membership.reload.presence_tokens.size
    assert @membership.connected?
  end

  test "concurrent duplicate absence consumes one token only once" do
    stale = @membership.present
    current = @membership.present

    outcomes = run_concurrently(8) { Membership.find(@membership.id).absent(stale) }

    assert_equal 1, outcomes.count(true)
    assert_equal 7, outcomes.count(false)
    assert_equal [ current.token ], @membership.reload.presence_tokens.keys
    assert @membership.connected?
  end

  test "concurrent connections cannot exceed the token limit" do
    (Membership::Connectable::MAXIMUM_PRESENCE_TOKENS - 4).times { @membership.present }

    presences = run_concurrently(8) { Membership.find(@membership.id).present }.compact

    assert_equal 4, presences.size
    assert_equal 4, presences.map(&:token).uniq.size
    assert_equal Membership::Connectable::MAXIMUM_PRESENCE_TOKENS, @membership.reload.presence_tokens.size
  end

  test "refresh converges when disconnect all races the live channel" do
    original = @membership.present

    outcomes = run_operations(
      -> { Membership.disconnect_all },
      -> { Membership.find(@membership.id).refresh_presence(original) }
    )
    first_replacement = outcomes.find { _1.is_a?(Membership::Connectable::Presence) }
    assert first_replacement

    final_replacement = @membership.reload.refresh_presence(first_replacement)
    assert final_replacement
    assert @membership.reload.connected?
    assert_equal [ final_replacement.token ], @membership.presence_tokens.keys
    assert_not @membership.absent(original)
  end

  private
    def run_concurrently(count, &operation)
      run_operations(*Array.new(count, operation))
    end

    def run_operations(*operations)
      barrier = Concurrent::CyclicBarrier.new(operations.size)
      results = Queue.new
      threads = operations.map do |operation|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            barrier.wait
            results << operation.call
          rescue StandardError => error
            results << error
          end
        end
      end
      threads.each(&:join)
      outcomes = operations.size.times.map { results.pop }
      errors = outcomes.grep(Exception)
      assert_empty errors, errors.inspect
      outcomes
    end
end
