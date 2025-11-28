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

  test "creating a blank message with attachment that exceeds max attachment limit" do
    ApplicationController.helpers.expects(:is_attachment_size_valid).returns(false)

    assert_raises(ActiveRecord::RecordInvalid) do
      create_attachment_message("moon.jpg", "image/jpeg")
    end
  end

  test "creating a blank message with attachment that doesn't exceed max attachment limit" do
    ApplicationController.helpers.expects(:is_attachment_size_valid).returns(true)

    assert_nothing_raised do
      create_attachment_message("moon.jpg", "image/jpeg")
    end
  end



  private
    def create_attachment_message(file, content_type)
      rooms(:hq).messages.create_with_attachment! \
        creator: users(:david),
        client_message_id: "message",
        attachment: fixture_file_upload(file, content_type)
    end
end
