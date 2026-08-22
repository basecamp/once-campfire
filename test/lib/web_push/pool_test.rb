require "test_helper"

class WebPush::PoolTest < ActiveSupport::TestCase
  FakeSubscription = Data.define(:id)
  FakeRecord = Data.define(:id)

  test "shutdown drains accepted work and rejects new work" do
    started = Queue.new
    release = Queue.new
    pool = WebPush::Pool.new(
      invalid_subscription_handler: nil,
      max_threads: 1,
      delivery_handler: ->(*) { started << true; release.pop }
    )
    delivery = Thread.new { queue_delivery(pool) }
    started.pop

    shutdown = Thread.new { pool.shutdown }
    wait_until { pool.delivery_pool.shuttingdown? }

    assert_predicate delivery, :alive?
    assert_predicate shutdown, :alive?
    assert_raises(WebPush::Pool::ShutdownError) { queue_delivery(pool) }

    release << true
    delivery.value
    shutdown.value
  ensure
    release << true if delivery&.alive?
    delivery&.join(2)
    shutdown&.join(2)
    pool&.shutdown unless pool&.delivery_pool&.shuttingdown?
  end

  test "a saturated pool applies caller backpressure instead of dropping work" do
    started = Queue.new
    release = Queue.new
    caller_thread_id = nil
    pool = WebPush::Pool.new(
      invalid_subscription_handler: nil,
      max_threads: 1,
      max_queue: 1,
      delivery_handler: ->(_payload, id, *) { started << [ id, Thread.current.object_id ]; release.pop }
    )
    delivery = Thread.new do
      caller_thread_id = Thread.current.object_id
      queue_delivery(pool, count: 3)
    end

    first_two = [ started.pop, started.pop ]
    assert_includes first_two.map(&:last), caller_thread_id
    assert_predicate delivery, :alive?

    2.times { release << true }
    started.pop
    release << true
    delivery.value
  ensure
    3.times { release << true } if release
    delivery&.join(2)
    pool&.shutdown
  end

  private
    def queue_delivery(pool, count: 1)
      subscriptions = Array.new(count) { |index| FakeSubscription.new(index + 1) }
      relation = Object.new
      relation.define_singleton_method(:find_each) { |&block| subscriptions.each(&block) }
      pool.queue({}, relation, room: FakeRecord.new(1), message: FakeRecord.new(1))
    end

    def wait_until(timeout: 2)
      Timeout.timeout(timeout) do
        sleep 0.01 until yield
      end
    end
end
