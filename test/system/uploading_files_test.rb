require "application_system_test_case"

class UploadingFilesTest < ApplicationSystemTestCase
  setup do
    @allow_forgery_protection = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true

    sign_in "jz@37signals.com"
    join_room rooms(:designers)
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @allow_forgery_protection
  end

  test "uploading a file with forgery protection on" do
    attach_file file_fixture("moon.jpg"), make_visible: true do
      find(".composer__attachment-btn").click
    end
    find("#composer [data-action='composer#submit']").click

    message = wait_for_uploaded_message
    assert_equal "moon.jpg", message.attachment.filename.to_s
    assert_selector "#" + dom_id(message)
    assert_no_selector "[data-pending-message]"
  end

  private
    # The upload is asynchronous, so give the server a moment to save the message
    def wait_for_uploaded_message(room: rooms(:designers))
      20.times do
        message = room.messages.with_attached_attachment.ordered.last
        return message if message.attachment.attached?
        sleep 0.25
      end
      flunk "no uploaded message was saved"
    end
end
