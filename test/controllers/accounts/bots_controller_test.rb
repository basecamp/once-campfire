require "test_helper"

class Accounts::BotsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "index" do
    get account_bots_url
    assert_response :ok
    assert_includes response.body, "Authorization: Bearer #{users(:bender).bot_key}"
  end

  test "create" do
    get new_account_bot_url
    assert_response :ok

    post account_bots_url, params: { user: { name: "Bender's Friend" } }
    assert_redirected_to account_bots_url
    assert_equal "Bender's Friend", User.bot.last.name
  end

  test "update" do
    get edit_account_bot_url(users(:bender))
    assert_response :ok

    put account_bot_url(users(:bender)), params: { user: { name: "Bender's New Friend" } }
    assert_redirected_to account_bots_url
    assert_equal "Bender's New Friend", users(:bender).reload.name
  end

  test "destroy" do
    assert_difference -> { User.active_bots.count }, -1 do
      delete account_bot_url(users(:bender))
    end

    assert users(:bender).reload.deactivated?
  end

  test "remove webhook" do
    assert_difference -> { Webhook.count }, -1 do
      put account_bot_url(users(:bender)), params: { user: { name: "Bender's New Friend", webook_url: "" } }
      assert_redirected_to account_bots_url
    end
  end
end
