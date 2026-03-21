require "test_helper"

class Users::AvatarsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "show initials" do
    get user_avatar_url(users(:kevin).avatar_token)
    assert_select "text", text: "K"
  end

  test "show image" do
    users(:kevin).update! avatar: fixture_file_upload("moon.jpg", "image/jpeg")
    get user_avatar_url(users(:kevin).avatar_token)

    assert_response :success
    assert_equal "image/webp", @response.content_type
  end

  test "show image when active storage service has no path_for" do
    with_pathless_active_storage_service do
      users(:kevin).update! avatar: fixture_file_upload("moon.jpg", "image/jpeg")

      get user_avatar_url(users(:kevin).avatar_token)

      assert_response :success
      assert_equal "image/webp", @response.content_type
    end
  end

  test "show image with invalid token responds 404" do
    get user_avatar_url("not-a-valid-token")

    assert_response :not_found
  end
end
