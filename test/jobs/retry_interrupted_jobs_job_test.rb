require "test_helper"

class RetryInterruptedJobsJobTest < ActiveSupport::TestCase
  test "retries only interrupted jobs that are safe to run again, a few times" do
    interrupted_destroy = failed Room::DestroyJob.new(rooms(:watercooler), []), interrupted
    broken_destroy = failed Room::DestroyJob.new(rooms(:hq), []), RuntimeError.new("boom")
    interrupted_webhook = failed Bot::WebhookJob.new(users(:bender), messages(:first)), interrupted
    interrupted_removal = failed RemoveBannedContentJob.new(users(:kevin)), interrupted
    exhausted_destroy = failed Room::DestroyJob.new(rooms(:pets), []), interrupted, executions: 3

    RetryInterruptedJobsJob.perform_now

    assert interrupted_destroy.reload.ready?
    assert_equal 1, interrupted_destroy.arguments["executions"]
    assert_not broken_destroy.reload.ready?
    assert_not interrupted_webhook.reload.ready?
    assert_not interrupted_removal.reload.ready?
    assert_not exhausted_destroy.reload.ready?
  end

  private
    def interrupted
      SolidQueue::Processes::ProcessPrunedError.new(1.minute.ago)
    end

    def failed(active_job, error, executions: 0)
      active_job.executions = executions
      SolidQueue::Job.enqueue(active_job).tap do |job|
        job.ready_execution.destroy!
        job.failed_with(error)
      end
    end
end
