class ApplicationJob < ActiveJob::Base
  # Automatically retry jobs that encountered a deadlock
  # retry_on ActiveRecord::Deadlocked

  # Most jobs are safe to ignore if the underlying records are no longer available
  # discard_on ActiveJob::DeserializationError

  thread_cattr_accessor :pending_enqueues, instance_accessor: false

  # Each Solid Queue enqueue is its own write transaction on the queue database.
  # Jobs enqueued inside the block are written together, in order, when it ends.
  # They are written even if the block raises, as they would have been one by one.
  # Enqueue after commit inside the block: a collected job is written even if its transaction rolls back.
  def self.enqueue_together
    return yield if pending_enqueues

    begin
      self.pending_enqueues = []
      yield
    ensure
      jobs, self.pending_enqueues = pending_enqueues, nil
      ActiveJob.perform_all_later(jobs) if jobs.any?
    end
  end

  def enqueue(options = {})
    if options.empty? && (jobs = ApplicationJob.pending_enqueues)
      jobs << self
      self
    else
      super
    end
  end
end
