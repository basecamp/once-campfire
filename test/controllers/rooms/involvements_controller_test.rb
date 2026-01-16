require "test_helper"

class Rooms::InvolvementsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "show" do
    get room_involvement_url(rooms(:designers))
    assert_response :success
  end

  test "update involvement sends turbo update when becoming visible and when going invisible" do
    assert_turbo_stream_broadcasts [ users(:david), :rooms ], count: 1 do
    assert_changes -> { memberships(:david_watercooler).reload.involvement }, from: "everything", to: "invisible" do
      put room_involvement_url(rooms(:watercooler)), params: { involvement: "invisible" }
      assert_redirected_to room_involvement_url(rooms(:watercooler))
    end
    end

    assert_turbo_stream_broadcasts [ users(:david), :rooms ], count: 2 do
    assert_changes -> { memberships(:david_watercooler).reload.involvement }, from: "invisible", to: "everything" do
      put room_involvement_url(rooms(:watercooler)), params: { involvement: "everything" }
      assert_redirected_to room_involvement_url(rooms(:watercooler))
    end
    end
  end

  test "updating involvement does not send turbo update changing visible states" do
    assert_no_turbo_stream_broadcasts [ users(:david), :rooms ] do
    assert_changes -> { memberships(:david_watercooler).reload.involvement }, from: "everything", to: "mentions" do
      put room_involvement_url(rooms(:watercooler)), params: { involvement: "mentions" }
      assert_redirected_to room_involvement_url(rooms(:watercooler))
    end
    end
  end

  test "updating involvement does not send turbo update for direct rooms" do
    assert_no_turbo_stream_broadcasts [ users(:david), :rooms ] do
    assert_changes -> { memberships(:david_david_and_jason).reload.involvement }, from: "everything", to: "nothing" do
      put room_involvement_url(rooms(:david_and_jason)), params: { involvement: "nothing" }
      assert_redirected_to room_involvement_url(rooms(:david_and_jason))
    end
    end
  end

  test "a non-admin can update their room involvement" do
    sign_in :jz

    assert_changes -> { memberships(:jz_designers).reload.involvement }, from: "everything", to: "mentions" do
      put room_involvement_url(rooms(:designers)), params: { involvement: "mentions" }
      assert_redirected_to room_involvement_url(rooms(:designers))
    end
  end
end
