require "test_helper"

class ActiveStorageRoutesTest < ActionDispatch::IntegrationTest
  setup do
    @blob = ActiveStorage::Blob.create_and_upload!(
      io: StringIO.new("legacy private bytes"), filename: "legacy.txt", content_type: "text/plain"
    )
  end

  test "legacy blob representation and disk routes are not mounted" do
    paths = [
      "/rails/active_storage/blobs/redirect/#{@blob.signed_id}/legacy.txt",
      "/rails/active_storage/blobs/proxy/#{@blob.signed_id}/legacy.txt",
      "/rails/active_storage/representations/redirect/#{@blob.signed_id}/legacy-variation/legacy.txt",
      "/rails/active_storage/disk/legacy-key/legacy.txt"
    ]

    paths.each do |path|
      assert_raises(ActionController::RoutingError) { get path }
    end
  end

  test "anonymous direct upload creation is not mounted" do
    assert_no_difference -> { ActiveStorage::Blob.count } do
      assert_raises(ActionController::RoutingError) do
        post "/rails/active_storage/direct_uploads", params: {
          blob: { filename: "anonymous.txt", byte_size: 1, checksum: "invalid", content_type: "text/plain" }
        }
      end
    end
  end

  test "custom account logo route remains available anonymously" do
    get account_logo_url

    assert_response :success
    assert_equal "image/png", response.media_type
  end
end
