require "application_system_test_case"

class UploadingFilesTest < ApplicationSystemTestCase
  setup do
    sign_in "jz@37signals.com"
    join_room rooms(:designers)
  end

  teardown do
    Message.singleton_class.remove_method(:create_with_attachment!) if Message.singleton_class.method_defined?(:create_with_attachment!, false)
    Rails.application.env_config["action_dispatch.show_exceptions"] = @show_exceptions if @show_exceptions
  end

  test "a file that can't reach the server is shown as failed" do
    attach_files "moon.jpg"

    page.driver.browser.network_conditions = { offline: true, latency: 0, throughput: 0 }
    click_on "send"

    assert_selector ".message--failed .message__pending-upload", text: "moon.jpg"
  ensure
    page.driver.browser.delete_network_conditions
  end

  test "a file the server refuses is shown as failed, and the files sent with it still arrive" do
    refuse_uploads_of "black_hole.jpg"
    attach_files "black_hole.jpg", "moon.jpg"

    click_on "send"

    assert_selector ".message--failed .message__pending-upload", text: "black_hole.jpg"
    assert_posted "moon.jpg"
  end

  test "a file sent after the session ended, as on signing out in another tab, is shown as failed" do
    attach_files "moon.jpg"
    users(:jz).sessions.destroy_all

    click_on "send"

    assert_selector ".message--failed .message__pending-upload", text: "moon.jpg"
  end

  test "a file sent to a room the sender can no longer reach is shown as failed" do
    attach_files "moon.jpg"
    memberships(:jz_designers).destroy

    click_on "send"

    assert_selector ".message--failed .message__pending-upload", text: "moon.jpg"
  end

  private
    def attach_files(*names)
      find("input[type=file][data-action~='composer#filePicked']", visible: :all).set(names.map { file_fixture(_1).to_s })
      names.each { assert_selector ".composer__file", text: File.basename(_1, ".*") }
    end

    def assert_posted(filename, wait: 10)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait

      until rooms(:designers).messages.joins(attachment_attachment: :blob).exists?(active_storage_blobs: { filename: filename })
        flunk "Expected #{filename} to be posted within #{wait}s" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.1
      end

      assert_no_selector "[data-pending-message] .message__pending-upload", text: filename
    end

    # The server answers 422 for that file, as it would for any refused request.
    def refuse_uploads_of(filename)
      @show_exceptions = Rails.application.env_config["action_dispatch.show_exceptions"]
      Rails.application.env_config["action_dispatch.show_exceptions"] = :rescuable

      Message.define_singleton_method(:create_with_attachment!) do |attributes|
        raise ActiveRecord::RecordInvalid if attributes[:attachment]&.original_filename == filename
        super(attributes)
      end
    end
end
