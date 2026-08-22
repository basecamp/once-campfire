class ReliableWork::Dispatcher
  INTERVAL = 1.second
  STAGED_UPLOAD_SWEEP_INTERVAL = 5.minutes
  TERMINAL_EFFECT_SWEEP_INTERVAL = 1.minute
  WORK_TYPES = [ BanCleanupIntent, Message::Effect ].freeze

  class << self
    def run
      loop do
        dispatch_pending
        sleep INTERVAL
      end
    end

    def dispatch_pending(now: Time.current)
      return false if @next_dispatch_at && now < @next_dispatch_at

      failure_count = @enqueue_failure_count.to_i + 1
      retry_delay = ReliableWork.enqueue_retry_delay(failure_count)
      WORK_TYPES.each { |work_type| dispatch work_type, enqueue_retry_delay: retry_delay }
      reset_enqueue_circuit
      sweep_staged_uploads
      sweep_terminal_effects
      true
    rescue StandardError => error
      raise unless ReliableWork.infrastructure_enqueue_error?(error)

      @enqueue_failure_count = failure_count
      @next_dispatch_at = now + retry_delay
      Rails.logger.error(
        "Reliable work enqueue unavailable error=#{error.class.name} " \
          "failures=#{failure_count} retry_in=#{retry_delay.to_i}s"
      )
      false
    end

    private
      def dispatch(work_type, enqueue_retry_delay:)
        work_type.dispatch_pending(
          enqueue_retry_delay:, raise_on_infrastructure_failure: true
        )
      rescue StandardError => error
        raise if ReliableWork.infrastructure_enqueue_error?(error)

        Rails.logger.error "Reliable work scan failed type=#{work_type.name} error=#{error.class.name}"
      end

      def reset_enqueue_circuit
        @enqueue_failure_count = 0
        @next_dispatch_at = nil
      end

      def sweep_staged_uploads
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return if @next_staged_upload_sweep_at && now < @next_staged_upload_sweep_at

        @next_staged_upload_sweep_at = now + STAGED_UPLOAD_SWEEP_INTERVAL.to_i
        StagedUpload.sweep_abandoned!
      rescue StandardError => error
        Rails.logger.error "Staged upload sweep failed error=#{error.class.name}"
      end

      def sweep_terminal_effects
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return if @next_terminal_effect_sweep_at && now < @next_terminal_effect_sweep_at

        @next_terminal_effect_sweep_at = now + TERMINAL_EFFECT_SWEEP_INTERVAL.to_i
        Message::Effect.prune_terminal!
      rescue StandardError => error
        Rails.logger.error "Terminal message effect sweep failed error=#{error.class.name}"
      end
  end
end
