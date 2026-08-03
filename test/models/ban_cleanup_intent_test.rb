require "test_helper"

class BanCleanupIntentTest < ActiveSupport::TestCase
  include ActionDispatch::TestProcess

  self.use_transactional_tests = false

  class UploadBarrierIO < StringIO
    def initialize(content, minimum_blob_id:, staged:, release:)
      super(content)
      @minimum_blob_id = minimum_blob_id
      @staged = staged
      @release = release
      @waited = false
    end

    def read(*)
      unless @waited
        blob = ActiveStorage::Blob.where(id: (@minimum_blob_id + 1)..).order(:id).first
        if blob
          @waited = true
          @staged << blob.id
          @release.pop
        end
      end
      super
    end
  end

  setup do
    @user = users(:kevin)
    @message = @user.messages.create!(
      room: rooms(:hq), body: "Moderated message", client_message_id: SecureRandom.hex(8)
    )
    clear_enqueued_jobs
  end

  test "unban committing first prevents an already-dispatched worker from deleting content" do
    @user.ban_by! actor: users(:david)
    intent = @user.ban_cleanup_intents.sole
    unban_ready = Queue.new
    release_unban = Queue.new
    worker_started = Queue.new

    unban = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.transaction do
          User.find(@user.id).unban_by! actor: users(:david)
          unban_ready << true
          release_unban.pop
        end
      end
    end
    wait_for_barrier unban_ready, unban
    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        worker_started << true
        perform_intent intent
      end
    end
    wait_for_barrier worker_started, worker

    assert_predicate worker, :alive?
    release_unban << true
    unban.value
    worker.value

    assert @message.reload
    assert @user.reload.active?
    assert intent.reload.canceled_at?
  ensure
    release_unban << true if unban&.alive?
    unban&.join(2)
    worker&.join(2)
  end

  test "cleanup committing first completes deletion before unban" do
    @user.ban_by! actor: users(:david)
    intent = @user.ban_cleanup_intents.sole
    cleanup_ready = Queue.new
    release_cleanup = Queue.new
    unban_started = Queue.new

    cleanup = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        BanCleanupIntent.transaction do
          perform_intent intent
          cleanup_ready << true
          release_cleanup.pop
        end
      end
    end
    wait_for_barrier cleanup_ready, cleanup
    unban = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        unban_started << true
        User.find(@user.id).unban_by! actor: users(:david)
      end
    end
    wait_for_barrier unban_started, unban

    assert_predicate unban, :alive?
    release_cleanup << true
    cleanup.value
    unban.value

    assert_not Message.exists?(@message.id)
    assert @user.reload.active?
    assert intent.reload.completed_at?
  ensure
    release_cleanup << true if cleanup&.alive?
    cleanup&.join(2)
    unban&.join(2)
  end

  test "a stale deactivation cannot overwrite a committed ban or cancel cleanup" do
    ban_ready = Queue.new
    release_ban = Queue.new
    ban_committed = Queue.new
    release_fence = Queue.new
    result = Queue.new
    User.any_instance.stubs(:disconnect_remote_connections)
    ban = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User::MutationFence.with(@user.id) do
          User.transaction do
            User.find(@user.id).ban_by! actor: users(:david)
            ban_ready << true
            release_ban.pop
          end
          ban_committed << true
          release_fence.pop
        end
      end
    end
    wait_for_barrier ban_ready, ban
    deactivation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.find(@user.id).deactivate_by! actor: users(:david)
        result << true
      rescue StandardError => error
        result << error
      end
    end

    assert_predicate deactivation, :alive?
    release_ban << true
    wait_for_barrier ban_committed, ban
    assert User.uncached { User.find(@user.id).banned? }
    assert_predicate deactivation, :alive?
    release_fence << true
    ban.value
    deactivation.value

    assert_kind_of User::AuthorizationError, result.pop
    assert @user.reload.banned?
    intent = @user.ban_cleanup_intents.sole
    assert BanCleanupIntent.pending.exists?(intent.id)
    assert perform_intent(intent)
    assert_not Message.exists?(@message.id)
  ensure
    release_ban << true if ban&.alive?
    release_fence << true if ban&.alive?
    ban&.join(2)
    deactivation&.join(2)
  end

  test "enqueue failure leaves durable work backed off for a later dispatcher pass" do
    RemoveBannedContentJob.stubs(:perform_later).raises(Redis::CannotConnectError)

    assert_nothing_raised { @user.ban_by! actor: users(:david) }
    intent = @user.ban_cleanup_intents.sole

    assert_nil intent.reload.lease_token
    assert_nil intent.completed_at
    assert_equal "Redis::CannotConnectError", intent.last_error_class
    assert_equal 0, intent.attempts
    assert_in_delta Time.current + ReliableWork::BASE_RETRY_DELAY, intent.next_attempt_at, 1.second
    assert @message.reload

    RemoveBannedContentJob.unstub(:perform_later)
    assert_not intent.dispatch
    travel_to intent.next_attempt_at + 1.second do
      assert_enqueued_jobs 1, only: RemoveBannedContentJob do
        assert intent.dispatch
      end
      perform_enqueued_jobs only: RemoveBannedContentJob
    end

    assert intent.reload.completed_at?
    assert_not Message.exists?(@message.id)
  end

  test "the Active Job entry point swallows a storage failure after durable retry is scheduled" do
    @message.destroy!
    @message = @user.messages.create_with_attachment!(
      room: rooms(:hq), client_message_id: SecureRandom.hex(8),
      attachment: { io: StringIO.new("retry bytes"), filename: "retry.txt", content_type: "text/plain" }
    )
    service = @message.attachment.blob.service
    service.stubs(:delete).raises(IOError, "storage unavailable")
    @user.ban_by! actor: users(:david)
    intent = @user.ban_cleanup_intents.sole

    assert_not RemoveBannedContentJob.perform_now(intent.id, intent.lease_token)

    assert_equal "IOError", intent.reload.last_error_class
    assert intent.next_attempt_at?
    assert_nil intent.lease_token
  ensure
    service&.unstub(:delete)
  end

  test "serialized legacy job dispatches the migrated intent once and removes banned content" do
    intent = insert_migrated_legacy_intent
    payload = RemoveBannedContentJob.new(@user).serialize
    assert_equal @user.to_global_id.to_s, payload.dig("arguments", 0, "_aj_globalid")

    assert_enqueued_jobs 1, only: RemoveBannedContentJob do
      2.times { ActiveJob::Base.execute(payload.deep_dup) }
    end

    assert_equal 1, @user.ban_cleanup_intents.where(generation: 1).count
    perform_enqueued_jobs only: RemoveBannedContentJob

    assert intent.reload.completed_at?
    assert_not Message.exists?(@message.id)
    assert_no_enqueued_jobs only: RemoveBannedContentJob do
      ActiveJob::Base.execute(payload.deep_dup)
    end
  end

  test "serialized legacy job refuses a later ban generation" do
    @user.update_columns(status: User.statuses.fetch("banned"), ban_cleanup_generation: 2)
    payload = RemoveBannedContentJob.new(@user).serialize

    assert_no_difference -> { @user.ban_cleanup_intents.count } do
      assert_no_enqueued_jobs only: RemoveBannedContentJob do
        ActiveJob::Base.execute(payload)
      end
    end

    assert Message.exists?(@message.id)
  end

  test "serialized cleanup job refuses ambiguous payload shapes" do
    intent = insert_migrated_legacy_intent
    scalar_payload = RemoveBannedContentJob.new(intent.id).serialize
    user_with_nil_payload = RemoveBannedContentJob.new(@user, nil).serialize
    assert_equal 1, scalar_payload.fetch("arguments").length
    assert_equal 2, user_with_nil_payload.fetch("arguments").length

    assert_no_enqueued_jobs only: RemoveBannedContentJob do
      ActiveJob::Base.execute(scalar_payload)
    end
    assert_no_enqueued_jobs only: RemoveBannedContentJob do
      ActiveJob::Base.execute(user_with_nil_payload)
    end

    assert BanCleanupIntent.pending.exists?(intent.id)
    assert_nil intent.reload.lease_token
    assert Message.exists?(@message.id)
  end

  test "completion requires attachment rows and bytes to be synchronously absent" do
    @message.destroy!
    @message = @user.messages.create_with_attachment!(
      room: rooms(:hq), client_message_id: SecureRandom.hex(8),
      attachment: { io: StringIO.new("banned bytes"), filename: "banned.txt", content_type: "text/plain" }
    )
    blob = @message.attachment.blob
    service = blob.service
    key = blob.key

    @user.ban_by! actor: users(:david)
    intent = @user.ban_cleanup_intents.sole
    assert perform_intent(intent)

    assert intent.reload.completed_at?
    assert_not Message.exists?(@message.id)
    assert_not ActiveStorage::Blob.exists?(blob.id)
    assert_not service.exist?(key)
  end

  test "completion synchronously removes attachment derivative blobs" do
    @message.destroy!
    @message = @user.messages.create_with_attachment!(
      room: rooms(:hq), client_message_id: SecureRandom.hex(8),
      attachment: fixture_file_upload("moon.jpg", "image/jpeg")
    )
    source = @message.attachment.blob.reload
    derivatives = source.variant_records.includes(:image_blob).filter_map(&:image_blob)
    assert_not_empty derivatives
    blobs = [ source, *derivatives ]

    @user.ban_by! actor: users(:david)
    intent = @user.ban_cleanup_intents.sole
    assert perform_intent(intent)

    blobs.each do |blob|
      assert_not ActiveStorage::Blob.exists?(blob.id)
      assert_not blob.service.exist?(blob.key)
    end
    assert intent.reload.completed_at?
  end

  test "a storage failure is resumable and unban cannot cancel a started purge" do
    @message.destroy!
    @message = @user.messages.create_with_attachment!(
      room: rooms(:hq), client_message_id: SecureRandom.hex(8),
      attachment: { io: StringIO.new("retry bytes"), filename: "retry.txt", content_type: "text/plain" }
    )
    blob = @message.attachment.blob
    service = blob.service
    service.stubs(:delete).raises(IOError, "storage unavailable")

    @user.ban_by! actor: users(:david)
    intent = @user.ban_cleanup_intents.sole
    assert_raises(IOError) { perform_intent(intent) }

    assert intent.reload.purge_started_at?
    assert_nil intent.completed_at
    assert_not Message.exists?(@message.id)
    @user.reload.unban_by! actor: users(:david)
    assert_nil intent.reload.canceled_at

    service.unstub(:delete)
    intent.update_columns(next_attempt_at: nil)
    assert perform_intent(intent.reload)
    assert intent.reload.completed_at?
    assert_not ActiveStorage::Blob.exists?(blob.id)
    assert_not service.exist?(blob.key)
  ensure
    service&.unstub(:delete)
  end

  test "required deletion remains pending beyond the ordinary dead-letter horizon" do
    @message.destroy!
    @message = @user.messages.create_with_attachment!(
      room: rooms(:hq), client_message_id: SecureRandom.hex(8),
      attachment: { io: StringIO.new("persistent retry"), filename: "retry.txt", content_type: "text/plain" }
    )
    blob = @message.attachment.blob
    service = blob.service
    service.stubs(:delete).raises(IOError, "storage unavailable")
    @user.ban_by! actor: users(:david)
    intent = @user.ban_cleanup_intents.sole

    (ReliableWork::MAX_ATTEMPTS + 2).times do |index|
      intent.update_columns(next_attempt_at: nil) if index.positive?
      assert_raises(IOError) { perform_intent(intent.reload) }
    end

    assert_nil intent.reload.failed_at
    assert BanCleanupIntent.pending.exists?(intent.id)
    assert_in_delta Time.current + ReliableWork::MAX_RETRY_DELAY, intent.next_attempt_at, 1.second

    service.unstub(:delete)
    intent.update_columns(next_attempt_at: nil)
    assert perform_intent(intent.reload)
    assert intent.reload.completed_at?
    assert_not service.exist?(blob.key)
  ensure
    service&.unstub(:delete)
  end

  test "message deletion is batched, resumable, and heartbeats its lease" do
    (BanCleanupIntent::MESSAGE_BATCH_SIZE * 2).times do |index|
      @user.messages.create!(
        room: rooms(:hq), body: "Batch #{index}", client_message_id: SecureRandom.hex(8)
      )
    end
    @user.ban_by! actor: users(:david)
    intent = @user.ban_cleanup_intents.sole
    original_batch = intent.method(:snapshot_message_batch!)
    batch_sizes = []
    test_case = self
    intent.define_singleton_method(:snapshot_message_batch!) do |lease_token|
      before = Message.where(creator_id: user_id).count
      result = original_batch.call(lease_token)
      if result
        batch_sizes << before - Message.where(creator_id: user_id).count
        test_case.send :travel, 10.minutes
        test_case.assert_not self.class.dispatchable.where(id: id).exists?
        raise IOError, "interrupted between batches" if batch_sizes.length == 2
      end
      result
    end

    assert_raises(IOError) { perform_intent(intent) }
    assert_equal 1, @user.messages.count
    assert_nil intent.reload.messages_deleted_at

    @user.reload.unban_by! actor: users(:david)
    retained_message = @user.messages.create!(
      room: rooms(:hq), body: "Created after cleanup started", client_message_id: SecureRandom.hex(8)
    )
    retained_staged = StagedUpload.stage(
      { io: StringIO.new("new staged bytes"), filename: "new.txt", content_type: "text/plain" },
      owner_id: @user.id
    )

    intent.update_columns(next_attempt_at: nil)
    assert perform_intent(intent)
    assert_equal [ 25, 25, 1 ], batch_sizes
    assert intent.reload.completed_at?
    assert Message.exists?(retained_message.id)
    assert ActiveStorage::Blob.exists?(retained_staged.id)
    assert retained_staged.service.exist?(retained_staged.key)
  ensure
    retained_staged&.purge
    travel_back
  end

  test "source staging that starts first remains fenced through attachment commit" do
    staged = Queue.new
    release_upload = Queue.new
    baseline_blob_id = ActiveStorage::Blob.maximum(:id).to_i
    upload = UploadBarrierIO.new(
      "fenced source", minimum_blob_id: baseline_blob_id, staged:, release: release_upload
    )
    creation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.find(@user.id).messages.create_with_attachment!(
          room: rooms(:hq), client_message_id: SecureRandom.hex(8),
          attachment: { io: upload, filename: "fenced.txt", content_type: "text/plain" }
        )
      end
    end
    blob_id = wait_for_barrier(staged, creation)
    blob = ActiveStorage::Blob.find(blob_id)
    assert_equal @user.id, blob.metadata.fetch(StagedUpload::OWNER_METADATA_KEY)
    ban = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.find(@user.id).ban_by! actor: users(:david)
      end
    end

    sleep 0.05
    assert_predicate ban, :alive?
    release_upload << true
    message = creation.value
    ban.value

    assert message.persisted?
    intent = @user.reload.ban_cleanup_intents.sole
    assert perform_intent(intent)
    assert_not ActiveStorage::Blob.exists?(blob.id)
    assert_not blob.service.exist?(blob.key)
  ensure
    release_upload << true if creation&.alive?
    creation&.join(2)
    ban&.join(2)
  end

  test "late derivative processing that starts first is included in the final purge snapshot" do
    message = create_unprocessed_image_message
    source = message.attachment.blob
    entered_lock = Queue.new
    release_processing = Queue.new
    original_lock = message.method(:with_attachment_processing_lock)
    test_case = self
    message.define_singleton_method(:with_attachment_processing_lock) do |&operation|
      original_lock.call do |attachment, uploads|
        entered_lock << true
        release_processing.pop
        test_case.assert_not ActiveRecord::Base.connection.transaction_open?
        operation.call attachment, uploads
      end
    end

    processing = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        message.processed_attachment_representation(:thumb)
      end
    end
    wait_for_barrier entered_lock, processing
    ban = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.find(@user.id).ban_by! actor: users(:david)
      end
    end

    sleep 0.05
    assert_predicate ban, :alive?
    release_processing << true
    processing.value
    ban.value

    derivatives = source.reload.variant_records.includes(:image_blob).filter_map(&:image_blob)
    assert_not_empty derivatives
    intent = @user.reload.ban_cleanup_intents.sole
    assert perform_intent(intent)
    [ source, *derivatives ].each do |blob|
      assert_not ActiveStorage::Blob.exists?(blob.id)
      assert_not blob.service.exist?(blob.key)
    end
  ensure
    release_processing << true if processing&.alive?
    processing&.join(2)
    ban&.join(2)
  end

  test "ban that commits first prevents late derivative publication" do
    message = create_unprocessed_image_message
    source = message.attachment.blob

    @user.ban_by! actor: users(:david)

    assert_raises(ActiveStorage::FileNotFoundError) do
      message.processed_attachment_representation(:thumb)
    end
    assert_empty source.reload.variant_records
    assert perform_intent(@user.ban_cleanup_intents.sole)
    assert_not ActiveStorage::Blob.exists?(source.id)
  end

  test "late preview processing is fenced before ban takes its recursive snapshot" do
    message = create_unprocessed_video_message
    source = message.attachment.blob
    entered_fence = Queue.new
    release_processing = Queue.new
    original_lock = message.method(:with_attachment_processing_lock)
    message.define_singleton_method(:with_attachment_processing_lock) do |&operation|
      original_lock.call do |attachment, registration|
        entered_fence << true
        release_processing.pop
        operation.call attachment, registration
      end
    end

    processing = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        message.processed_attachment_preview(format: :webp)
      end
    end
    wait_for_barrier entered_fence, processing
    ban = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.find(@user.id).ban_by! actor: users(:david)
      end
    end

    sleep 0.05
    assert_predicate ban, :alive?
    release_processing << true
    processing.value
    ban.value

    preview_blob = source.reload.preview_image.blob
    assert preview_blob
    intent = @user.reload.ban_cleanup_intents.sole
    assert perform_intent(intent)
    assert_not ActiveStorage::Blob.exists?(source.id)
    assert_not ActiveStorage::Blob.exists?(preview_blob.id)
    assert_not source.service.exist?(source.key)
    assert_not preview_blob.service.exist?(preview_blob.key)
  ensure
    release_processing << true if processing&.alive?
    processing&.join(2)
    ban&.join(2)
  end

  test "ban cleanup discovers an unattached derivative registration left by a crashed processor" do
    @message.destroy!
    @message = @user.messages.create_with_attachment!(
      room: rooms(:hq), client_message_id: SecureRandom.hex(8),
      attachment: { io: StringIO.new("source"), filename: "source.txt", content_type: "text/plain" }
    )
    staged = StagedUpload.stage(
      {
        io: StringIO.new("crashed derivative"), filename: "crashed.webp", content_type: "image/webp",
        metadata: {
          Message::Attachment::DERIVATIVE_USER_METADATA_KEY => @user.id,
          Message::Attachment::DERIVATIVE_SOURCE_METADATA_KEY => @message.attachment.blob_id
        }
      }
    )
    service = staged.service
    key = staged.key

    @user.ban_by! actor: users(:david)
    assert perform_intent(@user.ban_cleanup_intents.sole)

    assert_not ActiveStorage::Blob.exists?(staged.id)
    assert_not service.exist?(key)
  end

  test "ban cleanup discovers an owner-tagged source upload left by a crashed message creator" do
    staged = StagedUpload.stage(
      { io: StringIO.new("crashed source"), filename: "crashed.txt", content_type: "text/plain" },
      owner_id: @user.id
    )
    service = staged.service
    key = staged.key

    @user.ban_by! actor: users(:david)
    assert perform_intent(@user.ban_cleanup_intents.sole)

    assert_not ActiveStorage::Blob.exists?(staged.id)
    assert_not service.exist?(key)
  end

  test "owner discovery advances through bounded windows of unrelated blobs" do
    now = Time.current
    rows = (BanCleanupIntent::OWNED_BLOB_BATCH_SIZE + 1).times.map do
      {
        key: SecureRandom.base58(28), filename: "unrelated.txt", content_type: "text/plain",
        metadata: {}, service_name: "test", byte_size: 0, created_at: now
      }
    end
    unowned_ids = ActiveStorage::Blob.insert_all!(rows, returning: %w[ id ]).rows.flatten
    staged = StagedUpload.stage(
      { io: StringIO.new("owned"), filename: "owned.txt", content_type: "text/plain" },
      owner_id: @user.id
    )
    service = staged.service
    key = staged.key
    @user.ban_by! actor: users(:david)
    intent = @user.ban_cleanup_intents.sole
    original_batch = intent.method(:snapshot_owned_blob_batch!)
    batches = 0
    intent.define_singleton_method(:snapshot_owned_blob_batch!) do |lease_token|
      original_batch.call(lease_token).tap { batches += 1 if _1 }
    end

    assert perform_intent(intent)

    assert_operator batches, :>=, 2
    assert_equal unowned_ids.sort, ActiveStorage::Blob.where(id: unowned_ids).ids.sort
    assert_not ActiveStorage::Blob.exists?(staged.id)
    assert_not service.exist?(key)
  ensure
    ActiveStorage::Blob.where(id: unowned_ids).delete_all if unowned_ids
  end

  test "database terminal states reject completed and canceled cleanup together" do
    @user.ban_by! actor: users(:david)
    intent = @user.ban_cleanup_intents.sole

    assert_raises(ActiveRecord::StatementInvalid) do
      intent.update_columns(completed_at: Time.current, canceled_at: Time.current)
    end
  end

  private
    def wait_for_barrier(queue, worker, timeout: 10)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        return queue.pop(true)
      rescue ThreadError
        unless worker.alive?
          worker.value
          flunk "Worker exited before reaching the test barrier"
        end
        flunk "Timed out waiting for a worker test barrier" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
    end

    def insert_migrated_legacy_intent
      now = Time.current
      @user.update_columns(status: User.statuses.fetch("banned"), ban_cleanup_generation: 1)
      BanCleanupIntent.insert_all!([ {
        user_id: @user.id, generation: 1, created_at: now, updated_at: now
      } ])
      @user.ban_cleanup_intents.find_by!(generation: 1)
    end

    def perform_intent(intent)
      intent.reload
      token = intent.lease_token || intent.acquire_lease
      intent.perform! token
    end


    def create_unprocessed_image_message
      @message.destroy! if @message&.persisted?
      Message.any_instance.stubs(:process_attachment)
      @message = @user.messages.create_with_attachment!(
        room: rooms(:hq), client_message_id: SecureRandom.hex(8),
        attachment: fixture_file_upload("moon.jpg", "image/jpeg")
      )
    ensure
      Message.any_instance.unstub(:process_attachment)
    end

    def create_unprocessed_video_message
      @message.destroy! if @message&.persisted?
      Message.any_instance.stubs(:process_attachment)
      @message = @user.messages.create_with_attachment!(
        room: rooms(:hq), client_message_id: SecureRandom.hex(8),
        attachment: fixture_file_upload("alpha-centuri.mov", "video/quicktime")
      )
    ensure
      Message.any_instance.unstub(:process_attachment)
    end
end
