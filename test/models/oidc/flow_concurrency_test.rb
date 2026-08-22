require "test_helper"

class Oidc::FlowConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    configure_oidc
    Oidc::Flow.delete_all
    @browser_token = SecureRandom.urlsafe_base64(32)
  end

  teardown do
    Oidc::Flow.delete_all
  end

  test "cancellation committing first prevents callback mutation" do
    consumed = consume_flow
    start = Concurrent::CyclicBarrier.new(2)
    canceled = Concurrent::Event.new
    mutations = Concurrent::AtomicFixnum.new

    cancel_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        start.wait
        Oidc::Flow.cancel!(@browser_token).tap { canceled.set }
      end
    end
    callback_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        start.wait
        canceled.wait
        assert_raises(Oidc::Flow::Invalid) do
          consumed.finalize! { mutations.increment }
        end
      end
    end

    assert cancel_thread.value
    callback_thread.value
    assert_equal 0, mutations.value
  end

  test "callback committing first makes cancellation report that it lost" do
    consumed = consume_flow
    callback_entered = Concurrent::Event.new
    cancellation_started = Concurrent::Event.new
    release_callback = Concurrent::Event.new
    mutations = Concurrent::AtomicFixnum.new

    callback_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        consumed.finalize! do
          callback_entered.set
          release_callback.wait
          mutations.increment
        end
      end
    end
    cancel_thread = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        callback_entered.wait
        cancellation_started.set
        Oidc::Flow.cancel!(@browser_token)
      end
    end

    cancellation_started.wait
    release_callback.set
    assert_equal 1, callback_thread.value
    assert_not cancel_thread.value
    assert_equal 1, mutations.value
  end

  private
    def consume_flow
      Oidc::Flow.start!(
        state: "state",
        nonce: "nonce",
        pkce_verifier: "verifier",
        browser_token: @browser_token,
        initiating_session_id: nil,
        linking_intent: nil
      )
      Oidc::Flow.consume!(state: "state", browser_token: @browser_token)
    end
end
