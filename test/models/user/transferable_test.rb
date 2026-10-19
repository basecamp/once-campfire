require "test_helper"

class User::TransferableTest < ActiveSupport::TestCase
  test "a transfer id finds its user" do
    assert_equal users(:david), User.find_by_transfer_id(users(:david).transfer_id)
  end

  test "a transfer id expires" do
    transfer_id = users(:david).transfer_id

    travel User::TRANSFER_LINK_EXPIRY_DURATION + 1.second

    assert_nil User.find_by_transfer_id(transfer_id)
  end

  test "a transfer id made before a password change stops working" do
    transfer_id = users(:david).transfer_id

    users(:david).update!(password: "a new secret123456")

    assert_nil User.find_by_transfer_id(transfer_id)
    assert_equal users(:david), User.find_by_transfer_id(users(:david).transfer_id)
  end

  test "other changes keep a transfer id working" do
    transfer_id = users(:david).transfer_id

    users(:david).update!(name: "Dave", email_address: "dave@37signals.com")

    assert_equal users(:david), User.find_by_transfer_id(transfer_id)
  end

  test "a transfer id finds only users in scope" do
    transfer_id = users(:david).transfer_id

    users(:david).deactivate

    assert_nil User.active.find_by_transfer_id(transfer_id)
  end
end
