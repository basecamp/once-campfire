require "test_helper"

class Account::JoinableTest < ActiveSupport::TestCase
  test "new accounts get a joinable code" do
    Account.destroy_all
    account = Account.create!(name: "Chat")
    assert_match /\w{4}-\w{4}-\w{4}/, account.join_code
  end

  test "accounts can reset join code" do
    assert_changes -> { accounts(:signal).reload.join_code } do
      accounts(:signal).reset_join_code! actor: users(:david)
    end
  end
end
