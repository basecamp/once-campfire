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

  private
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
