module ReliableWork
  extend ActiveSupport::Concern

  LEASE_DURATION = 15.minutes
  DISPATCH_BATCH_SIZE = 100
  MAX_ATTEMPTS = 8
  BASE_RETRY_DELAY = 5.seconds
  MAX_RETRY_DELAY = 15.minutes
  ERROR_MESSAGE_LIMIT = 2_000

  class EnqueueFailure < StandardError; end
  module RetryScheduled; end

  class << self
    def enqueue_retry_delay(failures)
      return MAX_RETRY_DELAY if failures >= MAX_ATTEMPTS

      [ BASE_RETRY_DELAY * (2**[ failures - 1, 0 ].max), MAX_RETRY_DELAY ].min
    end

    def infrastructure_enqueue_error?(error)
      errors = []
      while error && !errors.include?(error)
        errors << error
        error = error.cause
      end

      return false if errors.any? { |candidate| candidate.is_a?(ActiveJob::SerializationError) }

      errors.any? do |candidate|
        candidate.is_a?(EnqueueFailure) ||
          candidate.is_a?(ActiveJob::EnqueueError) ||
          (defined?(Redis::BaseError) && candidate.is_a?(Redis::BaseError)) ||
          (defined?(RedisClient::Error) && candidate.is_a?(RedisClient::Error))
      end
    end
  end

  included do
    after_create_commit :dispatch_safely, if: :dispatch_after_create_commit?
  end

  class_methods do
    def dispatch_pending(
      scope = pending, limit: DISPATCH_BATCH_SIZE,
      enqueue_retry_delay: ReliableWork.enqueue_retry_delay(1),
      raise_on_infrastructure_failure: false
    )
      now = Time.current
      dispatched = 0
      dispatchable(scope, now:).limit(limit).pluck(:id).each do |id|
        begin
          dispatched += 1 if find_by(id:)&.dispatch(enqueue_retry_delay:)
        rescue StandardError => error
          Rails.logger.error "Reliable work dispatch failed type=#{name} id=#{id} error=#{error.class.name}"
          next unless ReliableWork.infrastructure_enqueue_error?(error)

          raise if raise_on_infrastructure_failure
          break
        end
      end
      dispatched
    end

    def dispatchable(scope = pending, now: Time.current)
      scope
        .where("next_attempt_at IS NULL OR next_attempt_at <= ?", now)
        .where("lease_token IS NULL OR COALESCE(started_at, enqueued_at) < ?", now - LEASE_DURATION)
        .order(Arel.sql("COALESCE(next_attempt_at, created_at) ASC"), :created_at, :id)
    end
  end

  def dispatch(enqueue_retry_delay: ReliableWork.enqueue_retry_delay(1))
    token, retained_token = acquire_dispatch_lease
    return false unless token

    enqueued_job = nil
    result = self.class::JOB_CLASS.perform_later(id, token) { |job| enqueued_job = job }
    unless result
      raise(enqueued_job&.enqueue_error || EnqueueFailure.new("#{self.class::JOB_CLASS.name} was not enqueued"))
    end
    true
  rescue StandardError => error
    if token
      if retained_token
        record_redispatch_failure! token, error
      else
        release_dispatch_claim! token, error, retry_delay: enqueue_retry_delay
      end
    end
    raise
  end

  def dispatch_safely(enqueue_retry_delay: ReliableWork.enqueue_retry_delay(1))
    dispatch(enqueue_retry_delay:)
  rescue StandardError => error
    Rails.logger.error "Reliable work dispatch failed type=#{self.class.name} id=#{id} error=#{error.class.name}"
    false
  end

  def dispatch_after_create_commit?
    true
  end

  def acquire_lease
    acquire_dispatch_lease.first
  end

  def release_for_continuation!(token)
    now = Time.current
    self.class.pending.where(id:, lease_token: token).update_all(
      lease_token: nil, enqueued_at: nil, started_at: nil, next_attempt_at: nil,
      attempts: Arel.sql("MAX(attempts - 1, 0)"), updated_at: now
    ) == 1
  end

  def mark_retry_scheduled(error)
    error.extend RetryScheduled
    error
  end

  def acquire_dispatch_lease
    now = Time.current
    retained_token = self.class.dispatchable(
      self.class.pending.where(id:, started_at: nil).where.not(lease_token: nil), now:
    ).pick(:lease_token)
    if retained_token
      retained = self.class.pending.where(
        id:, lease_token: retained_token, started_at: nil
      ).where("enqueued_at < ?", now - LEASE_DURATION).update_all(
        enqueued_at: now, updated_at: now
      )
      return [ retained_token, true ] if retained == 1
    end

    token = SecureRandom.uuid
    claimable = self.class.dispatchable(self.class.pending.where(id:), now:)
      .where("lease_token IS NULL OR started_at IS NOT NULL")
    claimed = claimable.update_all(
      lease_token: token, enqueued_at: now, started_at: nil, updated_at: now
    )
    [ (token if claimed == 1), false ]
  end

  def claim_for_processing!(token)
    now = Time.current
    self.class.pending.where(id:, lease_token: token, started_at: nil).update_all(
      started_at: now, attempts: Arel.sql("attempts + 1"), updated_at: now
    ) == 1
  end

  def complete!(token)
    now = Time.current
    self.class.pending.where(id:, lease_token: token).update_all(
      completed_at: now, lease_token: nil, enqueued_at: nil, started_at: nil,
      next_attempt_at: nil, updated_at: now
    ) == 1
  end

  def release_for_retry!(token, error)
    attempts = self.class.pending.where(id:, lease_token: token).pick(:attempts)
    return false unless attempts

    now = Time.current
    attributes = error_attributes(error, now:).merge(
      lease_token: nil, enqueued_at: nil, started_at: nil, updated_at: now
    )
    if attempts >= MAX_ATTEMPTS && dead_letter_after_max_attempts?
      attributes[:failed_at] = now
      attributes[:next_attempt_at] = nil
    else
      attributes[:next_attempt_at] = now + retry_delay(attempts)
    end

    self.class.pending.where(id:, lease_token: token).update_all(attributes) == 1
  end

  def retry_dead_letter!
    with_lock do
      raise ActiveRecord::RecordInvalid, self unless failed_at?

      update!(
        attempts: 0, failed_at: nil, next_attempt_at: nil, lease_token: nil,
        enqueued_at: nil, started_at: nil
      )
    end
    dispatch_safely
  end

  private
    def release_dispatch_claim!(token, error, retry_delay:)
      now = Time.current
      self.class.pending.where(id:, lease_token: token, started_at: nil).update_all(
        error_attributes(error, now:).merge(
          lease_token: nil, enqueued_at: nil, started_at: nil,
          next_attempt_at: now + retry_delay, updated_at: now
        )
      )
    end

    def record_redispatch_failure!(token, error)
      now = Time.current
      self.class.pending.where(id:, lease_token: token, started_at: nil).update_all(
        error_attributes(error, now:).merge(updated_at: now)
      )
    end

    def retry_delay(attempts)
      return MAX_RETRY_DELAY if attempts >= MAX_ATTEMPTS

      [ BASE_RETRY_DELAY * (2**(attempts - 1)), MAX_RETRY_DELAY ].min
    end

    def dead_letter_after_max_attempts?
      true
    end

    def error_attributes(error, now:)
      {
        last_error_class: error.class.name,
        last_error_message: error.message.to_s.byteslice(0, ERROR_MESSAGE_LIMIT),
        last_error_at: now
      }
    end
end
