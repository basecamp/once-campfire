require "test_helper"

class ActiveStorageAuthenticationTest < ActionDispatch::IntegrationTest
  setup do
    host! "once.campfire.test"
  end

  test "direct upload metadata endpoint rejects anonymous callers" do
    get new_session_url
    assert_response :success

    assert_no_difference -> { ActiveStorage::Blob.count } do
      post rails_direct_uploads_url, params: blob_params, as: :json
    end

    assert_response :unauthorized
  end

  test "direct upload metadata endpoint allows authenticated users" do
    sign_in :david

    assert_difference -> { ActiveStorage::Blob.count }, 1 do
      post rails_direct_uploads_url, params: blob_params, as: :json
    end

    assert_response :success
  end

  test "disk service upload endpoint rejects anonymous callers" do
    sign_in :david
    post rails_direct_uploads_url, params: blob_params, as: :json
    assert_response :success
    upload_path = URI.parse(response.parsed_body.dig("direct_upload", "url")).request_uri

    anonymous = open_session
    anonymous.host! "once.campfire.test"
    anonymous.put upload_path,
      params: attachment_bytes,
      headers: { "Content-Type" => "application/octet-stream" }

    assert_equal 401, anonymous.status
  end

  test "disk service download endpoint stays public" do
    ActiveStorage::Current.url_options = { host: "once.campfire.test", protocol: "https" }
    blob = ActiveStorage::Blob.create_and_upload! \
      io: StringIO.new(attachment_bytes), filename: "hi.txt", content_type: "text/plain"
    download_path = URI.parse(blob.url).request_uri

    anonymous = open_session
    anonymous.host! "once.campfire.test"
    anonymous.get download_path

    assert_equal 200, anonymous.status
    assert_equal attachment_bytes, anonymous.response.body
  ensure
    blob&.purge
  end

  private
    def attachment_bytes
      "hello!"
    end

    def blob_params
      { blob: {
        filename: "quota.bin",
        byte_size: attachment_bytes.bytesize,
        checksum: Digest::MD5.base64digest(attachment_bytes),
        content_type: "application/octet-stream"
      } }
    end
end
