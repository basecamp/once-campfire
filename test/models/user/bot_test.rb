require "test_helper"

class User::BotTest < ActiveSupport::TestCase
  test "create bot" do
    token = "5M0aLYwQyBXOXa5Wsz6NZb11EE4tW2"
    SecureRandom.stubs(:alphanumeric).returns(token)

    uuid = "3574925f-479d-44f8-82b7-fc039af5367c"
    Random.stubs(:uuid).returns(uuid)

    bot = User.create_bot!(name: "Bender")
    assert_equal "#{bot.id}-#{token}", bot.bot_key
  end

  test "reset bot key" do
    first_token = "5M0aLYwQyBXOXa5Wsz6NZb11EE4tW2"
    SecureRandom.stubs(:alphanumeric).returns(first_token)

    bot = User.create_bot!(name: "Bender")
    assert_equal "#{bot.id}-#{first_token}", bot.bot_key

    second_token = "R4kme9anwWRuz3sSoBXiB8Li8ioZPP"
    SecureRandom.stubs(:alphanumeric).returns(second_token)

    bot.reset_bot_key
    assert_equal "#{bot.id}-#{second_token}", bot.bot_key
  end

  test "authenticate" do
    bot = User.create_bot!(name: "Bender")
    assert User.authenticate_bot(bot.bot_key)
  end

  test "authenticate rejects a key without a token" do
    bot = User.create_bot!(name: "Bender")
    bot.update_column(:bot_token, nil)

    assert_nil User.authenticate_bot("#{bot.id}")
    assert_nil User.authenticate_bot("#{bot.id}-")
  end

  test "authenticate rejects a key with an empty token" do
    bot = User.create_bot!(name: "Bender")
    bot.update_column(:bot_token, "")

    assert_nil User.authenticate_bot("#{bot.id}--anything")
  end

  test "deliver message by webhook" do
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    perform_enqueued_jobs only: Bot::WebhookJob do
      users(:bender).deliver_webhook_later(messages(:first))
    end
  end
end
