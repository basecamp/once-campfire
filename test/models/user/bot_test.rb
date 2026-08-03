require "test_helper"

class User::BotTest < ActiveSupport::TestCase
  test "create bot" do
    token = "5M0aLYwQyBXOXa5Wsz6NZb11EE4tW2"
    SecureRandom.stubs(:alphanumeric).returns(token)

    uuid = "3574925f-479d-44f8-82b7-fc039af5367c"
    Random.stubs(:uuid).returns(uuid)

    bot = User.create_bot!({ name: "Bender" }, actor: users(:david))
    assert_equal "#{bot.id}-#{token}", bot.bot_key
  end

  test "reset bot key" do
    first_token = "5M0aLYwQyBXOXa5Wsz6NZb11EE4tW2"
    SecureRandom.stubs(:alphanumeric).returns(first_token)

    bot = User.create_bot!({ name: "Bender" }, actor: users(:david))
    assert_equal "#{bot.id}-#{first_token}", bot.bot_key

    second_token = "R4kme9anwWRuz3sSoBXiB8Li8ioZPP"
    SecureRandom.stubs(:alphanumeric).returns(second_token)

    bot.reset_bot_key! actor: users(:david)
    assert_equal "#{bot.id}-#{second_token}", bot.bot_key
  end

  test "authenticate" do
    bot = User.create_bot!({ name: "Bender" }, actor: users(:david))
    assert User.authenticate_bot(bot.bot_key)
  end

  test "deliver message by webhook" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    perform_enqueued_jobs only: Bot::WebhookJob do
      users(:bender).deliver_webhook_later(messages(:first))
    end
  end

  test "a queued webhook delivery does not survive URL rotation" do
    bot = users(:bender)
    webhook = webhooks(:bender)
    message = direct_message_for(bot)
    original_generation = webhook.delivery_generation
    original_request = WebMock.stub_request(:post, webhook.url).to_return(status: 200)

    webhook.update!(url: "https://example.com/rotated")
    bot.deliver_webhook(
      message, webhook_id: webhook.id, webhook_generation: original_generation, delivery_id: SecureRandom.uuid
    )

    assert_not_requested original_request
  end

  test "a queued webhook delivery does not survive membership revocation" do
    bot = users(:bender)
    webhook = webhooks(:bender)
    message = direct_message_for(bot)
    request = WebMock.stub_request(:post, webhook.url).to_return(status: 200)

    memberships(:bender_bender_and_kevin).destroy!
    bot.deliver_webhook(
      message, webhook_id: webhook.id, webhook_generation: webhook.delivery_generation,
      delivery_id: SecureRandom.uuid
    )

    assert_not_requested request
  end

  test "a queued legacy webhook delivery is safely discarded" do
    request = WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    Bot::WebhookJob.perform_now(users(:bender), messages(:first), SecureRandom.uuid)

    assert_not_requested request
  end

  test "a late webhook failure rolls back the bot and its staged avatar" do
    User.any_instance.stubs(:create_webhook!).raises(ActiveRecord::RecordInvalid.new(Webhook.new))

    assert_no_difference [ -> { User.count }, -> { ActiveStorage::Blob.count } ] do
      assert_raises(ActiveRecord::RecordInvalid) do
        User.create_bot!({
          name: "Failed bot", webhook_url: "https://example.test/hook",
          avatar: { io: StringIO.new("bot avatar"), filename: "bot.txt", content_type: "text/plain" }
        }, actor: users(:david))
      end
    end
  end

  test "a demoted administrator cannot commit a staged bot update" do
    actor = users(:david)
    bot = users(:bender)
    actor.update!(role: :member)

    assert_no_difference -> { ActiveStorage::Blob.count } do
      assert_raises(User::AuthorizationError) do
        bot.update_bot!({
          name: "Unauthorized bot",
          avatar: { io: StringIO.new("bot avatar"), filename: "bot.txt", content_type: "text/plain" }
        }, actor:)
      end
    end

    assert_not_equal "Unauthorized bot", bot.reload.name
  end

  private
    def direct_message_for(bot)
      rooms(:bender_and_kevin).messages.create!(
        creator: users(:kevin), body: "Message for #{bot.name}", client_message_id: SecureRandom.hex(8)
      ).tap { clear_enqueued_jobs }
    end
end
