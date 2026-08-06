require "test_helper"

class UserTest < ActiveSupport::TestCase
  test "user does not prevent very long passwords" do
    users(:david).update(password: "secret" * 50)
    assert users(:david).valid?
  end

  test "creating users grants membership to the open rooms" do
    assert_difference -> { Membership.count }, +Rooms::Open.count do
      create_new_user
    end
  end

  test "normalizes email case and supported edge whitespace" do
    user = User.create!(
      name: "Unicode User", email_address: "\tJÖRG@EXAMPLE.COM \r\n", password: "secret123456"
    )

    assert_equal "jörg@example.com", user.email_address
    assert_equal user.email_address, user.normalized_email_address
    assert_equal "\u00A0jörg@example.com\u00A0",
      User.normalize_email_address("\u00A0JÖRG@EXAMPLE.COM\u00A0")
  end

  test "database uniqueness uses the normalized email" do
    User.create!(name: "First", email_address: " Case@Example.COM ", password: "secret123456")

    assert_raises ActiveRecord::RecordNotUnique do
      User.create!(name: "Second", email_address: "case@example.com", password: "secret123456")
    end
  end

  test "deactivating a user deletes push subscriptions, searches, memberships for non-direct rooms, and changes their email address" do
    assert_difference -> { Membership.count }, -users(:david).memberships.without_direct_rooms.count do
    assert_difference -> { Push::Subscription.count }, -users(:david).push_subscriptions.count do
    assert_difference -> { Search.count }, -users(:david).searches.count do
      SecureRandom.stubs(:uuid).returns("2e7de450-cf04-4fa8-9b02-ff5ab2d733e7")
      users(:david).deactivate_by! actor: users(:jason)
      assert_equal "david-deactivated-2e7de450-cf04-4fa8-9b02-ff5ab2d733e7@37signals.com", users(:david).reload.email_address
    end
    end
    end
  end

  test "deactivating a user deletes their sessions" do
    user = users(:david)
    user.sessions.start!(user_agent: "Second browser", ip_address: "192.0.2.2")
    channel = ApplicationCable::Connection.user_internal_channel(user)

    assert_difference -> { ActionCable.server.pubsub.broadcasts(channel).size }, 1 do
    assert_changes -> { user.sessions.count }, from: 2, to: 0 do
      users(:david).deactivate_by! actor: users(:jason)
    end
    end

    payload = ActiveSupport::JSON.decode(ActionCable.server.pubsub.broadcasts(channel).last)
    assert_equal({
      "type" => "disconnect", "reason" => Session::REVOKED_REASON, "reconnect" => false
    }, payload)
  end

  private
    def create_new_user
      User.create!(name: "User", email_address: "user@example.com", password: "secret123456")
    end
end
