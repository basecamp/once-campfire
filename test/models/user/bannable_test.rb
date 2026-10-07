require "test_helper"

class User::BannableTest < ActiveSupport::TestCase
  test "banned users are visible to administrators only" do
    users(:kevin).banned!

    assert_includes User.visible_to(users(:david)), users(:kevin)
    assert_not_includes User.visible_to(users(:jz)), users(:kevin)
  end
end
