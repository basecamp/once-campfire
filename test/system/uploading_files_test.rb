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

    assert_selector ".message__body", text: "moon.jpg"
    assert_no_selector "[data-pending-message]"
    assert_equal "moon.jpg", rooms(:designers).messages.ordered.last.attachment.filename.to_s
  end
end
