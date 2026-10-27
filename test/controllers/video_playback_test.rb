require "test_helper"

class VideoPlaybackTest < ActionDispatch::IntegrationTest
  setup do
    host! "once.campfire.test"
    sign_in :david
  end

  test "a video's file can be asked for again hours after it started playing" do
    room = rooms(:watercooler)
    room.messages.create_with_attachment! creator: users(:david), attachment: fixture_file_upload("alpha-centuri.mov", "video/quicktime")

    get room_messages_url(room)
    get css_select("video").sole["src"]
    assert_response :redirect
    file_url = response.location

    get file_url, headers: { "Range" => "bytes=0-" }
    assert_response :partial_content

    # A browser asks for the rest of a playing video at the URL it was redirected to, not at the one in the page:
    # after a pause, and every time the response is cut short.
    travel 2.hours

    get file_url, headers: { "Range" => "bytes=1048576-" }
    assert_response :partial_content
  end
end
