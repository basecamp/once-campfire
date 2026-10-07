require "test_helper"

class Message::AttachmentTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionDispatch::TestProcess

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

  test "creating a message keeps an image that can't be decoded" do
    webp = Vips::Image.new_from_file(file_fixture("moon.jpg").to_s).webpsave_buffer
    message = create_unreadable_attachment_message(webp.byteslice(0, webp.bytesize / 2), "broken.webp")

    assert_equal "broken.webp", message.reload.attachment.filename.to_s
    assert_nil message.attachment.representation(:thumb).image
  end

  test "creating a message keeps a video that can't be decoded" do
    message = create_unreadable_attachment_message(file_fixture("alpha-centuri.mov").binread(64), "broken.mov")

    assert_equal "broken.mov", message.reload.attachment.filename.to_s
    assert_not message.attachment.preview(format: :webp).image.attached?
  end

  test "creating a message makes the video poster that the room shows" do
    message = create_attachment_message("alpha-centuri.mov", "video/quicktime")

    assert_no_difference -> { ActiveStorage::VariantRecord.count } do
      message.reload.attachment.preview(:poster).processed
    end
  end

  test "video previews are drawn by the previewer with a time limit, from a frame within the first 5 seconds" do
    assert_includes ActiveStorage.previewers, TimeLimitedVideoPreviewer
    assert_not_includes ActiveStorage.previewers, ActiveStorage::Previewer::VideoPreviewer
    assert_includes ActiveStorage.video_preview_arguments, "gte(t\\,5)"
  end

  test "creating a message gives up on a video preview that takes longer than the time limit" do
    started = nil
    message = nil

    with_ffmpeg_sleeping(5.seconds) do
      stub_const(TimeLimitedVideoPreviewer, :TIME_LIMIT, 0.2) do
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        message = create_attachment_message("alpha-centuri.mov", "video/quicktime")
      end
    end

    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 2
    assert_not message.reload.attachment.preview(format: :webp).image.attached?
  end

  test "creating a message makes no thumbnail of an image with more pixels than the limit" do
    moon = Vips::Image.new_from_file(file_fixture("moon.jpg").to_s)

    stub_const(Message::Attachment, :THUMBNAIL_MAX_PIXELS, moon.width * moon.height) do
      assert create_attachment_message("moon.jpg", "image/jpeg").attachment.representation(:thumb).processed?
    end

    stub_const(Message::Attachment, :THUMBNAIL_MAX_PIXELS, moon.width * moon.height - 1) do
      assert_not create_attachment_message("moon.jpg", "image/jpeg").attachment.representation(:thumb).processed?
    end
  end

  test "creating a message makes no preview of a video with more pixels than the limit" do
    stub_const(Message::Attachment, :THUMBNAIL_MAX_PIXELS, 1) do
      message = create_attachment_message("alpha-centuri.mov", "video/quicktime")
      assert_not message.reload.attachment.preview(format: :webp).image.attached?
    end
  end

  private
    def with_ffmpeg_sleeping(duration)
      Tempfile.create("ffmpeg") do |ffmpeg|
        ffmpeg.write "#!/bin/sh\n[ \"$1\" = \"-version\" ] && exit 0\nexec sleep #{duration.to_i}\n"
        ffmpeg.close
        File.chmod 0o755, ffmpeg.path

        previous, ActiveStorage.paths[:ffmpeg] = ActiveStorage.paths[:ffmpeg], ffmpeg.path
        yield
      ensure
        ActiveStorage.paths[:ffmpeg] = previous
      end
    end

    def create_attachment_message(file, content_type)
      rooms(:hq).messages.create_with_attachment! \
        creator: users(:david),
        client_message_id: "message",
        attachment: fixture_file_upload(file, content_type)
    end

    def create_unreadable_attachment_message(content, filename)
      rooms(:hq).messages.create_with_attachment! \
        creator: users(:david),
        client_message_id: "message",
        attachment: { io: StringIO.new(content), filename: filename }
    end
end
