require "test_helper"

class SessionTest < ActiveSupport::TestCase
  test "start a session" do
    assert_difference -> { users(:david).sessions.count }, +1 do
      users(:david).sessions.create!(user_agent: "This device", ip_address: "127.0.0.1")
    end
  end

  test "a session doesn't start on a password checked before it changed" do
    user = User.find(users(:david).id)
    User.find(user.id).update!(password: "a new secret123456")

    assert_no_difference -> { Session.count } do
      assert_raises(ActiveRecord::RecordInvalid) do
        user.sessions.create!(user_agent: "This device", ip_address: "127.0.0.1")
      end
    end
  end
end
