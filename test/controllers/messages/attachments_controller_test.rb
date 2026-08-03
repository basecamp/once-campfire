require "test_helper"

class Messages::AttachmentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "once.campfire.test"
    sign_in :david
    @message = rooms(:designers).messages.first
    @message.attachment.attach(
      io: StringIO.new("private attachment bytes"),
      filename: "private.txt",
      content_type: "text/plain"
    )
    @url = room_message_attachment_url(@message.room, @message)
  end

  test "streams attachment bytes only through a private authenticated response" do
    get @url

    assert_response :success
    assert_equal "private attachment bytes", response.body
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_equal "Cookie", response.headers["Vary"]
  end

  test "a retained URL stops working after room access is revoked" do
    get @url
    assert_response :success

    memberships(:david_designers).destroy!
    get @url

    assert_response :not_found
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_equal "Cookie", response.headers["Vary"]
  end

  test "download responses use attachment disposition" do
    get room_message_attachment_url(@message.room, @message, disposition: "attachment")

    assert_response :success
    assert_match(/attachment/, response.headers["Content-Disposition"])
    assert_match(/private\.txt/, response.headers["Content-Disposition"])
  end

  test "streams one byte range with private headers" do
    get @url, headers: { "Range" => "bytes=0-6" }

    assert_response :partial_content
    assert_equal "private", response.body
    assert_equal "bytes 0-6/24", response.headers["Content-Range"]
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_equal "Cookie", response.headers["Vary"]
  end

  test "rejects multipart byte ranges without downloading them" do
    ActiveStorage::Blob.any_instance.expects(:download_chunk).never

    get @url, headers: { "Range" => "bytes=0-1,4-5" }

    assert_response :range_not_satisfiable
    assert_equal "bytes */24", response.headers["Content-Range"]
    assert_equal "bytes", response.headers["Accept-Ranges"]
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_equal "Cookie", response.headers["Vary"]
  end

  test "rejects an unsatisfiable range with a wire-correct content range" do
    get @url, headers: { "Range" => "bytes=100-200" }

    assert_response :range_not_satisfiable
    assert_equal "bytes */24", response.headers["Content-Range"]
    assert_equal "bytes", response.headers["Accept-Ranges"]
    assert_empty response.body
  end

  test "missing storage returns 404 without partial response headers" do
    ActiveStorage::Blob.any_instance.stubs(:download_chunk).raises(ActiveStorage::FileNotFoundError)

    get @url, headers: { "Range" => "bytes=0-6" }

    assert_response :not_found
    assert_nil response.headers["Content-Range"]
    assert_nil response.headers["Accept-Ranges"]
    assert_not_equal "7", response.headers["Content-Length"]
    assert_empty response.body
  end

  test "missing storage on a full response returns a private 404" do
    ActiveStorage::Blob.any_instance.stubs(:download).raises(ActiveStorage::FileNotFoundError)

    get @url

    assert_response :not_found
    assert_equal "private, no-store", response.headers["Cache-Control"]
    assert_equal "Cookie", response.headers["Vary"]
    assert_nil response.headers["Content-Range"]
    assert_nil response.headers["Accept-Ranges"]
    assert_empty response.body
  end

  test "streams a large range in bounded chunks" do
    body = "x" * (Messages::AttachmentsController::RANGE_CHUNK_SIZE * 2 + 17)
    @message.attachment.attach(io: StringIO.new(body), filename: "large.txt", content_type: "text/plain")
    ranges = []
    subscriber = ActiveSupport::Notifications.subscribe("service_download_chunk.active_storage") do |event|
      ranges << event.payload.fetch(:range)
    end

    get @url, headers: { "Range" => "bytes=0-" }

    assert_response :partial_content
    assert_equal body, response.body
    assert_operator ranges.length, :>, 1
    assert ranges.all? { |range| range.size <= Messages::AttachmentsController::RANGE_CHUNK_SIZE }
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end
end
