require "test_helper"

class UserBanFlagTest < ActiveSupport::TestCase
  test "should read and write ban flag" do
    user = User.new(name: "Test User", email_address: "test@example.com", password: "password")

    assert_not user.banned, "Default ban should be false"

    user.banned = true
    assert user.banned, "Ban should be true after setting"
    user.save!
    user.reload
    assert user.banned, "Ban should persist after save and reload"

    user.banned = false
    user.save!
    user.reload
    assert_not user.banned, "Ban should be false after resetting"
  end
end
