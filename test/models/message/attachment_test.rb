require "test_helper"

class Message::AttachmentTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionDispatch::TestProcess

  class OwnershipObservingIO < StringIO
    attr_reader :owner_id_seen_during_upload

    def initialize(content, minimum_blob_id:)
      super(content)
      @minimum_blob_id = minimum_blob_id
    end

    def read(*)
      if blob = ActiveStorage::Blob.where(id: (@minimum_blob_id + 1)..).order(:id).first
        @owner_id_seen_during_upload = blob.metadata[StagedUpload::OWNER_METADATA_KEY]
      end
      super
    end
  end

  class FenceObservingIO < StringIO
    def initialize(content, user_id:, on_read: nil)
      super(content)
      @user_id = user_id
      @on_read = on_read
      @fence_held_during_read = false
    end

    def read(*)
      @fence_held_during_read ||= User::MutationFence.held?(@user_id)
      @on_read&.call
      @on_read = nil
      super
    end

    def fence_held_during_read?
      @fence_held_during_read
    end
  end

  test "creating a message creates image thumbnail" do
    message = create_attachment_message("moon.jpg", "image/jpeg")
    assert message.attachment.representation(:thumb).image.present?
  end

  test "creating a message creates video preview" do
    message = create_attachment_message("alpha-centuri.mov", "video/quicktime")
    assert message.reload.attachment.preview(format: :webp).image.attached?
  end

  test "creating a blank message with attachment will use filename as plain text body" do
    message = create_attachment_message("moon.jpg", "image/jpeg")
    assert_equal message.plain_text_body, "moon.jpg"
  end

  test "derived processing failure cannot turn a committed message into a retryable failure" do
    Message.any_instance.stubs(:ensure_attachment_analyzed).raises("processing failed")

    assert_difference -> { Message.count }, +1 do
      message = create_attachment_message("moon.jpg", "image/jpeg")
      assert message.persisted?
      assert message.attachment.attached?
    end
  end

  test "message attachments do not enqueue automatic Active Storage analysis" do
    Message.any_instance.stubs(:process_attachment)

    assert_no_enqueued_jobs only: ActiveStorage::AnalyzeJob do
      message = create_attachment_message("moon.jpg", "image/jpeg")
      assert_not message.attachment.blob.analyzed?
    end
  ensure
    Message.any_instance.unstub(:process_attachment)
  end

  test "retrying one client message id converges on the committed attachment" do
    first = create_attachment_message("moon.jpg", "image/jpeg")

    assert_no_difference -> { Message.count } do
      retry_message = create_attachment_message("earth.png", "image/png")
      assert_equal first, retry_message
      assert_equal "moon.jpg", retry_message.attachment.filename.to_s
    end
  end

  test "an idempotent retry revalidates the exact session before effects" do
    room = rooms(:hq)
    creator = users(:david)
    existing = room.messages.create_with_attachment!(
      creator:, body: "Committed", client_message_id: "credential-bound-retry"
    )
    presented_session = Session.find(sessions(:david_safari).id)
    User::MutationFence.with(creator.id) do
      Session.find(presented_session.id).regenerate_token
    end
    Message.any_instance.expects(:perform_reliable_effects).never

    assert_raises(User::AuthorizationError) do
      room.messages.create_with_attachment!(
        creator:, body: "Retry", client_message_id: existing.client_message_id,
        authenticated_session: presented_session
      )
    end
  end

  test "a uniqueness-race retry revalidates the exact session before effects" do
    room = rooms(:designers)
    room_messages = room.messages
    creator = users(:david)
    existing = messages(:second)
    presented_session = Session.find(sessions(:david_safari).id)
    ActiveRecord::AssociationRelation.any_instance.expects(:find_by)
      .with({ client_message_id: existing.client_message_id }).twice.returns(nil, existing)
    ActiveRecord::AssociationRelation.any_instance.stubs(:create!)
      .raises(ActiveRecord::RecordNotUnique)
    credential_checks = sequence("exact credential checks")
    Session.expects(:authenticate_exact!).in_sequence(credential_checks).returns(presented_session)
    Session.expects(:authenticate_exact!).in_sequence(credential_checks)
      .raises(User::AuthorizationError, "authenticated session was revoked")
    Message.any_instance.expects(:perform_reliable_effects).never

    assert_raises(User::AuthorizationError) do
      room_messages.create_with_attachment!(
        creator:, body: "Retry", client_message_id: existing.client_message_id,
        authenticated_session: presented_session
      )
    end
  end

  test "the same client message ID cannot be claimed by another creator" do
    room = rooms(:designers)
    client_message_id = "creator-owned-client-id"
    original = room.messages.create_with_attachment!(
      creator: users(:jason), body: "Original", client_message_id:
    )

    assert_no_difference [ -> { Message.count }, -> { Message::Effect.count } ] do
      assert_raises Message::ClientMessageIdConflict do
        room.messages.create_with_attachment!(
          creator: users(:david), body: "Collision", client_message_id:
        )
      end
    end

    assert_equal users(:jason), original.reload.creator
    assert_equal "Original", original.plain_text_body
  end

  test "rejects an oversized client message id before retry lookup" do
    room = rooms(:hq)
    creator = users(:david)
    client_message_id = "x" * (ContentLimits::CLIENT_MESSAGE_ID_BYTES + 1)

    assert_no_difference [ -> { Message.count }, -> { Message::Effect.count } ] do
      assert_queries_count(0) do
        assert_raises(ContentLimits::Exceeded) do
          room.messages.create_with_attachment!(creator:, body: "Oversized ID", client_message_id:)
        end
      end
    end
  end

  test "storage failure cannot commit a message or leave an orphan blob" do
    service = ActiveStorage::Blob.service
    service.stubs(:upload).raises(IOError, "simulated storage failure")

    assert_no_difference [ -> { Message.count }, -> { ActiveStorage::Blob.count }, -> { ActiveStorage::Attachment.count } ] do
      assert_raises(IOError) { create_text_attachment_message("failed-upload", "missing bytes") }
    end
  end

  test "same id retries after storage failure with one message and one durable blob" do
    service = ActiveStorage::Blob.service
    service.stubs(:upload).raises(IOError, "simulated storage failure")

    assert_raises(IOError) { create_text_attachment_message("retry-after-failure", "missing bytes") }
    service.unstub(:upload)

    assert_difference [ -> { Message.count }, -> { ActiveStorage::Blob.count }, -> { ActiveStorage::Attachment.count } ], 1 do
      message = create_text_attachment_message("retry-after-failure", "durable bytes")
      assert_equal "durable bytes", message.attachment.download
    end
  end

  test "staged source uploads retain trusted creator ownership metadata" do
    creator = users(:david)
    upload = OwnershipObservingIO.new("owned bytes", minimum_blob_id: ActiveStorage::Blob.maximum(:id).to_i)
    message = rooms(:hq).messages.create_with_attachment!(
      creator:, client_message_id: "owned-source",
      attachment: {
        io: upload, filename: "attachment.txt", content_type: "text/plain",
        metadata: { StagedUpload::OWNER_METADATA_KEY => users(:jz).id }
      }
    )

    assert_equal creator.id, upload.owner_id_seen_during_upload
    assert_equal creator.id, message.attachment.blob.metadata.fetch(StagedUpload::OWNER_METADATA_KEY)
  end

  test "source uploads are read outside the creator mutation fence" do
    creator = users(:david)
    upload = FenceObservingIO.new("source bytes", user_id: creator.id)

    rooms(:hq).messages.create_with_attachment!(
      creator:, client_message_id: "unfenced-source-upload",
      attachment: { io: upload, filename: "attachment.txt", content_type: "text/plain" },
      authenticated_session: sessions(:david_safari)
    )

    assert_not upload.fence_held_during_read?
  end

  test "a rotated authenticated session token cannot commit after source staging" do
    creator = users(:david)
    authenticated_session = Session.find(sessions(:david_safari).id)
    old_token = authenticated_session.token
    upload = FenceObservingIO.new(
      "source bytes", user_id: creator.id, on_read: -> {
        User::MutationFence.with(creator.id) do
          Session.find(authenticated_session.id).regenerate_token
        end
      }
    )

    assert_raises(User::AuthorizationError) do
      rooms(:hq).messages.create_with_attachment!(
        creator:, client_message_id: "revoked-source-upload",
        attachment: { io: upload, filename: "attachment.txt", content_type: "text/plain" },
        authenticated_session:
      )
    end

    assert_not Message.exists?(creator:, client_message_id: "revoked-source-upload")
    assert_not_equal old_token, Session.find(authenticated_session.id).token
  end

  test "a rotated bot key cannot commit after source staging" do
    creator = users(:bender)
    old_key = creator.bot_key
    upload = FenceObservingIO.new(
      "source bytes", user_id: creator.id,
      on_read: -> { User.find(creator.id).reset_bot_key!(actor: users(:david)) }
    )

    assert_raises(User::AuthorizationError) do
      rooms(:watercooler).messages.create_with_attachment!(
        creator:, client_message_id: "rotated-bot-upload",
        attachment: { io: upload, filename: "attachment.txt", content_type: "text/plain" },
        authenticated_bot_key: old_key
      )
    end

    assert_not Message.exists?(creator:, client_message_id: "rotated-bot-upload")
    assert_not_equal old_key, creator.reload.bot_key
  end

  test "a ban that commits first prevents source staging" do
    creator = users(:david)
    creator.update_columns(status: User.statuses.fetch("banned"))
    StagedUpload.expects(:stage).never

    assert_raises(User::AuthorizationError) do
      rooms(:hq).messages.create_with_attachment!(
        creator:, client_message_id: "banned-before-stage",
        attachment: { io: StringIO.new("blocked"), filename: "blocked.txt", content_type: "text/plain" }
      )
    end
  end

  test "message creation failure purges the staged blob" do
    Message.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid.new(Message.new))

    assert_no_difference [ -> { Message.count }, -> { ActiveStorage::Blob.count }, -> { ActiveStorage::Attachment.count } ] do
      assert_raises(ActiveRecord::RecordInvalid) do
        create_text_attachment_message("failed-message-create", "staged bytes")
      end
    end
  end

  test "retry preserves an unmarked pre-uploaded blob it does not own" do
    message = create_text_attachment_message("pre-upload-retry", "winning bytes")
    losing_blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("losing bytes"), filename: "loser.txt", content_type: "text/plain"
    )

    assert_no_difference -> { ActiveStorage::Blob.count } do
      retry_message = rooms(:hq).messages.create_with_attachment!(
        creator: users(:david), client_message_id: "pre-upload-retry", attachment: losing_blob
      )
      assert_equal message, retry_message
    end

    assert_equal "winning bytes", message.attachment.download
  ensure
    losing_blob&.purge
  end

  test "rejects a known oversized attachment before creating a blob" do
    upload = StringIO.new("small")
    upload.stubs(:size).returns(ContentLimits::ATTACHMENT_BYTES + 1)

    assert_no_difference -> { ActiveStorage::Blob.count } do
      assert_raises(ContentLimits::Exceeded) do
        rooms(:hq).messages.create_with_attachment!(
          creator: users(:david), client_message_id: "oversized-known",
          attachment: { io: upload, filename: "large.txt", content_type: "text/plain" }
        )
      end
    end
  end

  test "rejects a stream that exceeds its declared size" do
    upload = StringIO.new("12345")
    upload.stubs(:size).returns(1)

    assert_no_difference -> { ActiveStorage::Blob.count } do
      assert_raises(ContentLimits::Exceeded) do
        StagedUpload.stage(
          { io: upload, filename: "lying.txt", content_type: "text/plain" }, maximum: 4
        )
      end
    end
  end

  test "sweeper removes only old unattached staged uploads" do
    staged = StagedUpload.stage(
      { io: StringIO.new("abandoned"), filename: "abandoned.txt", content_type: "text/plain" }
    )
    recent = StagedUpload.stage(
      { io: StringIO.new("recent"), filename: "recent.txt", content_type: "text/plain" }
    )
    unmarked = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("unmarked"), filename: "unmarked.txt", content_type: "text/plain"
    )
    staged.update_columns(created_at: StagedUpload::GRACE_PERIOD.ago - 1.minute)
    unmarked.update_columns(created_at: StagedUpload::GRACE_PERIOD.ago - 1.minute)

    assert_difference -> { ActiveStorage::Blob.count }, -1 do
      StagedUpload.sweep_abandoned!
    end

    assert_not ActiveStorage::Blob.exists?(staged.id)
    assert ActiveStorage::Blob.exists?(recent.id)
    assert ActiveStorage::Blob.exists?(unmarked.id)
  ensure
    recent&.purge
    unmarked&.purge
  end

  test "sweeper preserves a staged blob that committed an attachment" do
    message = create_text_attachment_message("attached-staged", "attached bytes")
    blob = message.attachment.blob
    blob.update_columns(created_at: StagedUpload::GRACE_PERIOD.ago - 1.minute)

    assert_no_difference -> { ActiveStorage::Blob.count } do
      StagedUpload.sweep_abandoned!
    end

    assert_equal "attached bytes", message.attachment.download
  end

  test "attached staged blobs cannot starve an abandoned upload from a bounded sweep" do
    message = create_text_attachment_message("attached-before-orphan", "attached bytes")
    attached = message.attachment.blob
    attached.update_columns(created_at: StagedUpload::GRACE_PERIOD.ago - 2.minutes)
    abandoned = StagedUpload.stage(
      { io: StringIO.new("orphan"), filename: "orphan.txt", content_type: "text/plain" }
    )
    abandoned.update_columns(created_at: StagedUpload::GRACE_PERIOD.ago - 1.minute)

    StagedUpload.sweep_abandoned!(limit: 1)

    assert ActiveStorage::Blob.exists?(attached.id)
    assert_not ActiveStorage::Blob.exists?(abandoned.id)
  end

  test "sweeper resumes after bytes were deleted but the row transaction rolled back" do
    blob = StagedUpload.stage(
      { io: StringIO.new("interrupted"), filename: "interrupted.txt", content_type: "text/plain" }
    )
    blob.update_columns(created_at: StagedUpload::GRACE_PERIOD.ago - 1.minute)

    assert_raises(RuntimeError) do
      StagedUpload.sweep_abandoned!(fault_after_delete: ->(_blob) { raise "process interrupted" })
    end
    assert ActiveStorage::Blob.exists?(blob.id)
    assert_not blob.service.exist?(blob.key)

    StagedUpload.sweep_abandoned!
    assert_not ActiveStorage::Blob.exists?(blob.id)
  end


  private
    def create_attachment_message(file, content_type)
      rooms(:hq).messages.create_with_attachment! \
        creator: users(:david),
        client_message_id: "message",
        attachment: fixture_file_upload(file, content_type)
    end

    def create_text_attachment_message(client_message_id, body)
      rooms(:hq).messages.create_with_attachment!(
        creator: users(:david), client_message_id:,
        attachment: { io: StringIO.new(body), filename: "attachment.txt", content_type: "text/plain" }
      )
    end
end

class Message::AttachmentConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "concurrent same-id uploads retain one message and one blob" do
    room = rooms(:hq)
    creator = users(:david)
    client_message_id = "concurrent-staged-upload"
    barrier = Concurrent::CyclicBarrier.new(2)
    baseline_blob_count = ActiveStorage::Blob.uncached { ActiveStorage::Blob.count }
    results = Queue.new

    threads = 2.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait
          message = room.messages.create_with_attachment!(
            creator:, client_message_id:,
            attachment: {
              io: StringIO.new("bytes-#{index}"),
              filename: "attachment-#{index}.txt",
              content_type: "text/plain"
            }
          )
          results << message.id
        rescue StandardError => error
          results << error
        end
      end
    end
    threads.each(&:join)

    outcomes = 2.times.map { results.pop }
    assert outcomes.none? { |outcome| outcome.is_a?(Exception) }, outcomes.inspect
    assert_equal 1, room.messages.where(creator:, client_message_id:).count
    assert_equal 1, ActiveStorage::Attachment.where(record_type: "Message", record_id: outcomes).count
    assert_equal baseline_blob_count + 1, ActiveStorage::Blob.uncached { ActiveStorage::Blob.count }
  ensure
    room&.messages&.where(creator:, client_message_id:)&.find_each do |message|
      message.attachment.purge if message.attachment.attached?
      message.destroy!
    end
  end
end
