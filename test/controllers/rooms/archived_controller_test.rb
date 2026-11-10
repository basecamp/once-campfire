require "test_helper"

class Rooms::ArchivedControllerTest < ActionDispatch::IntegrationTest
  setup do
    @room = rooms(:designers)
    @room.update!(archived_at: Time.current)
    @room.memberships.delete_all
  end

  test "administrators can list archived rooms" do
    sign_in :david

    get rooms_archived_index_url

    assert_response :success
    assert_match @room.name, response.body
  end

  test "administrators can read an archived room" do
    sign_in :david

    get rooms_archived_url(@room)

    assert_response :success
    assert_match "This room is archived", response.body
    assert_select ".composer", count: 0
  end

  test "members cannot list archived rooms" do
    sign_in :kevin

    get rooms_archived_index_url

    assert_response :forbidden
  end
end
