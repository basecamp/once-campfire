class Bot::ActionWebhookJob < ApplicationJob
  def perform(bot, message, user, value, selected)
    bot.deliver_action_webhook(message, user, value, selected)
  end
end
