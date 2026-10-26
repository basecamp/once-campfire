# A job that's still running when its worker is stopped or killed (docker stop or kill, an update) is failed by
# Solid Queue, not retried. Retry it here if running it again from the start does no harm. Webhooks, Web Push and
# broadcasts are left failed, since they'd be delivered twice, and so is banned-content removal: the user may have
# been unbanned since.
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
