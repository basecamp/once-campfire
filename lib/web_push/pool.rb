# This is in lib so we can use it in a thread pool without the Rails executor
class WebPush::Pool
  DEFAULT_RETRY_DELAYS = [ 1, 5 ].freeze
  DEFINITIVE_EXPIRATION_ERRORS = [ WebPush::ExpiredSubscription, WebPush::InvalidSubscription ].freeze

  class TransientDeliveryError < StandardError
    def initialize(error, attempts:)
      super("Web Push delivery failed after #{attempts} attempts: #{error.class.name}")
    end
  end

  class ShutdownError < StandardError; end

  attr_reader :delivery_pool, :invalid_subscription_handler

  def initialize(invalid_subscription_handler:, max_threads: 50, max_queue: 10_000,
      retry_delays: DEFAULT_RETRY_DELAYS, sleeper: ->(delay) { sleep delay }, delivery_handler: nil)
    @delivery_pool = Concurrent::ThreadPoolExecutor.new(
      max_threads:, max_queue:, fallback_policy: :abort
    )
    @invalid_subscription_handler = invalid_subscription_handler
    @retry_delays = retry_delays
    @sleeper = sleeper
    @delivery_handler = delivery_handler
    @state_lock = Mutex.new
    @state_changed = ConditionVariable.new
    @accepting = true
    @caller_tasks = 0
  end

  def queue(payload, subscriptions, room:, message:)
    completions = []
    submission_error = begin
      subscriptions.find_each do |subscription|
        completions << submit do
          Rails.application.executor.wrap do
            deliver_with_retries(payload, subscription.id, room.id, message.id)
          end
        end
      end
      nil
    rescue StandardError => error
      error
    end

    delivery_error = completions.filter_map do |completion|
      _, error = completion.pop
      error
    end.first
    raise submission_error if submission_error
    raise delivery_error if delivery_error

    true
  end

  def shutdown
    should_shutdown = @state_lock.synchronize do
      if @accepting
        @accepting = false
        true
      else
        false
      end
    end
    delivery_pool.shutdown if should_shutdown
    delivery_pool.wait_for_termination
    @state_lock.synchronize do
      @state_changed.wait(@state_lock) while @caller_tasks.positive?
    end
    true
  end

  private
    def submit(&task)
      completion = Queue.new
      wrapped_task = -> do
        result = task.call
        completion << [ result, nil ]
      rescue StandardError => error
        completion << [ nil, error ]
      end

      run_in_caller = @state_lock.synchronize do
        raise ShutdownError, "Web Push delivery pool is shutting down" unless @accepting

        begin
          delivery_pool.post(&wrapped_task)
          false
        rescue Concurrent::RejectedExecutionError
          @caller_tasks += 1
          true
        end
      end
      run_caller_task(wrapped_task) if run_in_caller
      completion
    end

    def run_caller_task(task)
      task.call
    ensure
      @state_lock.synchronize do
        @caller_tasks -= 1
        @state_changed.broadcast
      end
    end

    def deliver_with_retries(payload, id, room_id, message_id)
      attempts = 0
      begin
        attempts += 1
        if @delivery_handler
          @delivery_handler.call(payload, id, room_id, message_id)
        else
          deliver(payload, id, room_id, message_id)
        end
      rescue *DEFINITIVE_EXPIRATION_ERRORS
        invalid_subscription_handler&.call(id)
      rescue StandardError => error
        raise unless retryable?(error)

        if attempts <= @retry_delays.length
          Rails.logger.warn "Retrying Web Push delivery subscription_id=#{id} attempt=#{attempts} error=#{error.class.name}"
          @sleeper.call @retry_delays.fetch(attempts - 1)
          retry
        end
        raise TransientDeliveryError.new(error, attempts:), cause: error
      end
    end

    def deliver(payload, id, room_id, message_id)
      message = Message.find_by(id: message_id, room_id: room_id)
      return unless message

      subscription = Push::Subscription.with_current_session
        .find_by(id: id)
      return unless subscription

      membership = subscription.user.memberships.find_by(room_id: room_id)
      return unless membership && !membership.connected? && membership.user_id != message.creator_id
      return unless membership.involved_in_everything? ||
        (membership.involved_in_mentions? && message.mentionees.exists?(id: membership.user_id))

      subscription.notification(**payload).deliver
    end

    def retryable?(error)
      return true if error.is_a?(WebPush::Endpoint::Unavailable)
      return true if error.is_a?(WebPush::TooManyRequests) || error.is_a?(WebPush::PushServiceError)
      return true if error.is_a?(OpenSSL::OpenSSLError) || error.is_a?(Timeout::Error)
      return true if error.is_a?(SocketError) || error.is_a?(SystemCallError)
      return true if error.is_a?(EOFError) || error.is_a?(IOError) || error.is_a?(Net::ProtocolError)
      return false unless error.is_a?(WebPush::ResponseError)

      status = error.response.code.to_i
      status.in?([ 408, 425, 429 ]) || status >= 500
    end
end
