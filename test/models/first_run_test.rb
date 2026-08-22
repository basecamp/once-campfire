require "test_helper"

class FirstRunTest < ActiveSupport::TestCase
  FIRST_RUN_TOKEN = "first-run-model-token-abcdefghijklmnopqrstuvwxyz"

  setup do
    FirstRun.stubs(:configured_token).returns(FIRST_RUN_TOKEN)
    Account.destroy_all
    Room.destroy_all
    User.destroy_all
  end

  test "creating makes first user an administrator" do
    user = create_first_run_user
    assert user.administrator?
  end

  test "first user has access to first room" do
    user = create_first_run_user
    assert user.rooms.one?
  end

  test "first room is an open room" do
    create_first_run_user
    assert Room.first.open?
  end

  test "a late setup failure rolls everything back and can be retried" do
    Membership.stubs(:insert_all).raises(ActiveRecord::StatementInvalid, "simulated membership failure")

    assert_no_difference [ -> { Account.count }, -> { User.count }, -> { Room.count }, -> { Membership.count } ] do
      assert_raises(ActiveRecord::StatementInvalid) { create_first_run_user }
    end

    Membership.unstub(:insert_all)
    user = create_first_run_user

    assert user.persisted?
    assert_equal 1, Account.count
    assert_equal 1, Room.count
    assert_equal [ user ], Room.first.users.to_a
  end

  test "setup requires the configured bootstrap token" do
    assert_no_difference [ -> { Account.count }, -> { User.count }, -> { Room.count } ] do
      assert_raises(FirstRun::Unauthorized) do
        FirstRun.create!(
          { name: "User", email_address: "user@example.com", password: "secret123456" },
          token: "wrong-token"
        )
      end
    end
  end

  test "short configured bootstrap tokens fail closed" do
    FirstRun.unstub(:configured_token)
    assert_nil FirstRun.configured_token(FirstRun::TOKEN_ENVIRONMENT_VARIABLE => "too-short")
  end

  private
    def create_first_run_user
      FirstRun.create!(
        { name: "User", email_address: "user@example.com", password: "secret123456" },
        token: FIRST_RUN_TOKEN
      )
    end
end
