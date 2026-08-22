require "test_helper"

class Accounts::BotsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "index" do
    get account_bots_url
    assert_response :ok
  end

  test "create" do
    get new_account_bot_url
    assert_response :ok

    post account_bots_url, params: { user: { name: "Bender's Friend" } }
    assert_redirected_to account_bots_url
    assert_equal "Bender's Friend", User.bot.last.name
  end

  test "create renders webhook validation errors without creating a bot" do
    assert_no_difference [ -> { User.bot.count }, -> { Webhook.count } ] do
      post account_bots_url, params: {
        user: { name: "Unsafe Bot", webhook_url: "http://internal.example.test/hook" }
      }
    end

    assert_response :unprocessable_entity
    assert_select "[role='alert']", text: /public HTTPS on port 443/i
    assert_select "input[name='user[webhook_url]'][value='http://internal.example.test/hook'][aria-invalid='true']"
  end

  test "update" do
    get edit_account_bot_url(users(:bender))
    assert_response :ok

    put account_bot_url(users(:bender)), params: { user: { name: "Bender's New Friend" } }
    assert_redirected_to account_bots_url
    assert_equal "Bender's New Friend", users(:bender).reload.name
  end

  test "update preserves the webhook when the parameter is absent" do
    webhook = webhooks(:bender)

    put account_bot_url(users(:bender)), params: { user: { name: "Renamed without webhook input" } }

    assert_redirected_to account_bots_url
    assert_equal webhook, users(:bender).reload.webhook
  end

  test "update renders webhook validation errors without changing the bot" do
    bot = users(:bender)
    original_name = bot.name
    original_url = bot.webhook.url

    put account_bot_url(bot), params: {
      user: { name: "Must roll back", webhook_url: "https://example.com:8443/hook" }
    }

    assert_response :unprocessable_entity
    assert_select "[role='alert']", text: /public HTTPS on port 443/i
    assert_select "input[name='user[webhook_url]'][value='https://example.com:8443/hook'][aria-invalid='true']"
    assert_equal original_name, bot.reload.name
    assert_equal original_url, bot.webhook.reload.url
  end

  test "bot avatar staging is unfenced and revalidates the exact session token at commit" do
    actor = users(:david)
    bot = users(:bender)
    authenticated_session = Session.find_by!(token: parsed_cookies.signed[:session_token])
    observed_fences = []
    original_stage = StagedUpload.method(:stage)
    StagedUpload.define_singleton_method(:stage) do |*arguments, **options|
      observed_fences << [
        User::MutationFence.held?(actor.id), User::MutationFence.held?(bot.id)
      ]
      original_stage.call(*arguments, **options).tap do
        User::MutationFence.with(actor.id) do
          Session.find(authenticated_session.id).regenerate_token
        end
      end
    end

    assert_no_difference -> { ActiveStorage::Blob.count } do
      put account_bot_url(bot), params: { user: {
        name: "Must not commit", avatar: fixture_file_upload("moon.jpg", "image/jpeg")
      } }
    end

    assert_response :forbidden
    assert_equal [ [ false, false ] ], observed_fences
    assert_not_equal "Must not commit", bot.reload.name
  ensure
    StagedUpload.define_singleton_method(:stage, original_stage) if original_stage
  end

  test "destroy" do
    assert_difference -> { User.active_bots.count }, -1 do
      delete account_bot_url(users(:bender))
    end

    assert users(:bender).reload.deactivated?
  end

  test "remove webhook" do
    assert_difference -> { Webhook.count }, -1 do
      put account_bot_url(users(:bender)), params: { user: { name: "Bender's New Friend", webhook_url: "" } }
      assert_redirected_to account_bots_url
    end
  end
end
