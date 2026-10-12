require "test_helper"

class RangedDownloadsTest < ActionDispatch::IntegrationTest
  setup do
    host! "once.campfire.test"
    ActiveStorage::Current.url_options = { host: "once.campfire.test", protocol: "https" }

    @blob = ActiveStorage::Blob.create_and_upload! io: StringIO.new("0123456789"), filename: "clip.mp4", content_type: "video/mp4"
    @file_path = URI.parse(@blob.url).request_uri
  end

  teardown do
    @blob.purge
  end

  test "the app sends a part of a file when nothing in front of it sends files" do
    get @file_path, headers: { "Range" => "bytes=2-5" }

    assert_response :partial_content
    assert_equal "bytes 2-5/10", response.headers["Content-Range"]
    assert_equal "2345", response.body
  end

  test "the app answers with the whole file when X-Sendfile is on, and leaves the part to Thruster" do
    with_x_sendfile do
      get @file_path, headers: { "Range" => "bytes=2-5" }
    end

    # Rack::Sendfile hands a whole file over as an X-Sendfile header, and Thruster, which still holds the browser's
    # request, sends the part that was asked for.
    assert_response :ok
    assert_nil response.headers["Content-Range"]
    assert_equal "0123456789", response.body
  end

  test "the app still answers a HEAD for a part of a file when X-Sendfile is on" do
    with_x_sendfile do
      head @file_path, headers: { "Range" => "bytes=2-5" }
    end

    assert_response :partial_content
    assert_equal "bytes 2-5/10", response.headers["Content-Range"]
  end

  private
    def with_x_sendfile
      Rails.application.config.action_dispatch.stubs(:x_sendfile_header).returns("X-Sendfile")
      yield
    end
end
