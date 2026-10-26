# Solid Queue fails the job a stopped or killed worker was running. Retry it where running it again is harmless.
class RetryInterruptedJobsJob < ApplicationJob
  RETRYABLE = %w[ Room::DestroyJob ActiveStorage::PurgeJob ]
  INTERRUPTIONS = %w[
    SolidQueue::Processes::ProcessExitError SolidQueue::Processes::ProcessPrunedError SolidQueue::Processes::ProcessMissingError
  ]
  MAX_RETRIES = 3

  def perform
    SolidQueue::FailedExecution.joins(:job).where(job: { class_name: RETRYABLE }).includes(:job).find_each do |execution|
      retry_interrupted(execution) if execution.exception_class.in?(INTERRUPTIONS)
    end
  end

  private
    # FailedExecution#retry resets the job's execution count, so it's counted here instead.
    def retry_interrupted(execution)
      job = execution.job
      retries = job.arguments["executions"].to_i
      return if retries >= MAX_RETRIES

      execution.with_lock do
        job.arguments["executions"] = retries + 1
        job.save!
        job.prepare_for_execution
        execution.destroy!
      end
    rescue ActiveRecord::RecordNotFound
      # Retried or discarded by hand in the meantime.
    end
end
