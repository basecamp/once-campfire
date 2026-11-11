require "test_helper"

class Internal::Backlit::RoomsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @token = "test-provisioning-token"
    ENV["BACKLIT_PROVISIONING_TOKEN"] = @token
    @headers = {
      "Authorization" => "Bearer #{@token}",
      "Content-Type" => "application/json",
      "Accept" => "application/json"
    }

    @user = User.create!(
      name: "Backlit Member",
      email_address: "member@example.com",
      sso_provider: "backlit",
      sso_uid: "42"
    )
  end

  teardown do
    ENV.delete("BACKLIT_PROVISIONING_TOKEN")
  end

  test "create room and sync memberships" do
    post internal_backlit_rooms_url, params: {
      name: "Announcements · Demo",
      backlit_project_id: "7",
      backlit_kind: "announcements"
    }.to_json, headers: @headers

    assert_response :created
    room_id = JSON.parse(response.body)["id"]

    post memberships_internal_backlit_room_url(room_id), params: { subs: [ "42" ] }.to_json, headers: @headers
    assert_response :success

    get memberships_internal_backlit_room_url(room_id), headers: @headers
    assert_response :success
    assert_equal [ "42" ], JSON.parse(response.body)["subs"]

    delete memberships_internal_backlit_room_url(room_id), params: { subs: [ "42" ] }.to_json, headers: @headers
    assert_response :success

    get memberships_internal_backlit_room_url(room_id), headers: @headers
    assert_equal [], JSON.parse(response.body)["subs"]
  end

  test "rejects requests without the provisioning token" do
    post internal_backlit_rooms_url, params: {
      name: "Chat · Demo",
      backlit_project_id: "7",
      backlit_kind: "chat"
    }.to_json, headers: { "Content-Type" => "application/json" }

    assert_response :unauthorized
  end

  test "archives and unarchives a room" do
    post internal_backlit_rooms_url, params: {
      name: "Admin · Demo",
      backlit_project_id: "9",
      backlit_kind: "admin"
    }.to_json, headers: @headers
    assert_response :created
    room_id = JSON.parse(response.body)["id"]

    post memberships_internal_backlit_room_url(room_id), params: { subs: [ "42" ] }.to_json, headers: @headers
    assert_response :success

    post archive_internal_backlit_room_url(room_id), headers: @headers
    assert_response :success
    room = Room.find(room_id)
    assert room.archived?
    assert_equal 0, room.memberships.count

    post unarchive_internal_backlit_room_url(room_id), headers: @headers
    assert_response :success
    assert_nil room.reload.archived_at
  end
end
