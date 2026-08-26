# This is in lib so we can use it in a thread pool without the Rails executor
class WebPush::Pool
  attr_reader :delivery_pool, :invalidation_pool, :connection, :invalid_subscription_handler

  def initialize(invalid_subscription_handler:)
    # max_queue (not queue_size, which ThreadPoolExecutor silently ignores) caps
    # the delivery backlog: an unbounded queue lets a flood of subscriptions
    # accumulate without limit, more so now that each task also resolves DNS.
    # Overflow raises RejectedExecutionError under the default :abort policy,
    # which deliver_later rescues -- push is best-effort and retried next message.
    @delivery_pool = Concurrent::ThreadPoolExecutor.new(max_threads: 50, max_queue: 10000)
    @invalidation_pool = Concurrent::FixedThreadPool.new(1)
    @connection = Net::HTTP::Persistent.new(name: "web_push", pool_size: 150)
    @invalid_subscription_handler = invalid_subscription_handler
  end

  def queue(payload, subscriptions)
    subscriptions.find_each do |subscription|
      deliver_later(payload, subscription)
    end
  end

  def shutdown
    connection.shutdown
    shutdown_pool(delivery_pool)
    shutdown_pool(invalidation_pool)
  end

  private
    def deliver_later(payload, subscription)
      # Ensure any AR operations happen before we post to the thread pool
      notification = subscription.notification(**payload)
      subscription_id = subscription.id

      delivery_pool.post do
        deliver(notification, subscription_id)
      rescue Exception => e
        Rails.logger.error "Error in WebPush::Pool.deliver: #{e.class} #{e.message}"
      end
    rescue Concurrent::RejectedExecutionError
    end

    def deliver(notification, id)
      notification.deliver(connection: connection)
    rescue WebPush::ExpiredSubscription, OpenSSL::OpenSSLError => ex
      invalidate_subscription_later(id) if invalid_subscription_handler
    end

    def invalidate_subscription_later(id)
      invalidation_pool.post do
        invalid_subscription_handler.call(id)
      rescue Exception => e
        Rails.logger.error "Error in WebPush::Pool.invalid_subscription_handler: #{e.class} #{e.message}"
      end
    end

    def shutdown_pool(pool)
      pool.shutdown
      pool.kill unless pool.wait_for_termination(1)
    end
end
