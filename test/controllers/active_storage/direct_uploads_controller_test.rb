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

  test "disk update requires authentication" do
    _blob, url = direct_upload_url_for("hello")

    put url, params: "hello", headers: { "Content-Type" => "text/plain" }

    assert_redirected_to new_session_url
  end

  test "disk update stores bytes for an authenticated session without a CSRF token" do
    sign_in :david
    blob, url = direct_upload_url_for("hello")

    # Forgery protection is off in test by default; turn it on so this proves the
    # signed-token service PUT stays CSRF-exempt even when the concern re-arms it.
    with_forgery_protection do
      put url, params: "hello", headers: { "Content-Type" => "text/plain" }
    end

    assert_response :no_content
    assert_equal "hello", blob.download
  end

  private
    def blob_params
      content = "hello"
      { filename: "hello.txt", byte_size: content.bytesize, content_type: "text/plain", \
        checksum: Digest::MD5.base64digest(content) }
    end

    def direct_upload_url_for(content)
      blob = ActiveStorage::Blob.create_before_direct_upload! \
        filename: "hello.txt", byte_size: content.bytesize, \
        checksum: Digest::MD5.base64digest(content), content_type: "text/plain"
      url = ActiveStorage::Current.set(url_options: { host: "once.campfire.test", protocol: "http" }) do
        blob.service_url_for_direct_upload
      end
      [ blob, url ]
    end

    def with_forgery_protection
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      yield
    ensure
      ActionController::Base.allow_forgery_protection = original
    end
end
