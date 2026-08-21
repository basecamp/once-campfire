require "test_helper"

class BotCredentialMutationTest < ActiveSupport::TestCase
  setup do
    @bot = users(:bender)
    @room = rooms(:watercooler)
    @message = @room.messages.create!(
      creator: @bot, body: "Original message", client_message_id: SecureRandom.uuid,
      origin: Message::ORIGIN_BOT_API
    )
    @boost = Boost.create_by!(message: @message, actor: @bot, attributes: { content: "Original boost" })
    @old_key = @bot.bot_key
    @bot.reset_bot_key! actor: users(:david)
  end

  test "a rotated bot key cannot update a message" do
    assert_raises(User::AuthorizationError) do
      @message.update_with_broadcast!(
        { body: "Unauthorized update" }, actor: @bot, authenticated_bot_key: @old_key
      )
    end

    assert_equal "Original message", @message.reload.plain_text_body
  end

  test "a rotated bot key cannot destroy a message" do
    assert_raises(User::AuthorizationError) do
      @message.destroy_with_broadcast!(actor: @bot, authenticated_bot_key: @old_key)
    end

    assert Message.exists?(@message.id)
  end

  test "a rotated bot key cannot create a boost" do
    assert_no_difference -> { Boost.count } do
      assert_raises(User::AuthorizationError) do
        Boost.create_by!(
          message: @message, actor: @bot, attributes: { content: "Unauthorized boost" },
          authenticated_bot_key: @old_key
        )
      end
    end
  end

  test "a rotated bot key cannot destroy a boost" do
    assert_no_difference -> { Boost.count } do
      assert_raises(User::AuthorizationError) do
        Boost.destroy_by!(id: @boost.id, actor: @bot, authenticated_bot_key: @old_key)
      end
    end
  end
end
