require "test_helper"

class ActiveStorage::DirectUploadsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! "once.campfire.test"
  end

  test "create requires authentication" do
    assert_no_difference -> { ActiveStorage::Blob.count } do
      post rails_direct_uploads_url, params: { blob: blob_params }
    end

    assert_redirected_to new_session_url
  end

  test "create succeeds for an authenticated session" do
    sign_in :david

    assert_difference -> { ActiveStorage::Blob.count }, 1 do
      post rails_direct_uploads_url, params: { blob: blob_params }
    end

    assert_response :success
  end

  test "disk show stays reachable without authentication" do
    blob = ActiveStorage::Blob.create_and_upload! \
      io: StringIO.new("hello"), filename: "hello.txt", content_type: "text/plain"

    ActiveStorage::Current.set(url_options: { host: "once.campfire.test", protocol: "http" }) do
      get blob.url
    end

    assert_response :success
  end

  private
    def blob_params
      content = "hello"
      { filename: "hello.txt", byte_size: content.bytesize, content_type: "text/plain", \
        checksum: Digest::MD5.base64digest(content) }
    end
end
