require "test_helper"

class PrepareBackupScriptTest < ActiveSupport::TestCase
  # SQLite can't back up a connection in the middle of a write transaction.
  self.use_transactional_tests = false

  teardown do
    SolidQueue::Job.delete_all
    SolidQueue::Process.delete_all
    backups.each { |path| FileUtils.rm_f(path) }
  end

  test "backs up the database and its queue, with the jobs running at the time" do
    running = SolidQueue::Job.enqueue(RemoveBannedContentJob.new(users(:kevin)))
    worker = SolidQueue::Process.create!(kind: "Worker", name: "worker", pid: 1, hostname: "campfire", last_heartbeat_at: Time.current)
    SolidQueue::ReadyExecution.claim("*", 1, worker.id)
    queued = SolidQueue::Job.enqueue(Room::DestroyJob.new(rooms(:watercooler), []))

    load Rails.root.join("script/admin/prepare-backup").to_s

    database, queue = backups.map { |path| SQLite3::Database.new(path.to_s) }
    assert_equal [ [ rooms(:watercooler).id ] ], database.execute("SELECT id FROM rooms WHERE id = ?", rooms(:watercooler).id)
    assert_equal [ running.id, queued.id ].sort, queue.execute("SELECT id FROM solid_queue_jobs").flatten.sort
    assert_equal [ [ running.id, worker.id ] ], queue.execute("SELECT job_id, process_id FROM solid_queue_claimed_executions")
  ensure
    [ database, queue ].compact.each(&:close)
  end

  private
    def backups
      [ ApplicationRecord, SolidQueue::Record ].map do |model|
        Rails.root.join("storage/backups", File.basename(model.connection_db_config.database))
      end
    end
end
