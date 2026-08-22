class Bot::WebhookJob < ApplicationJob
  def perform(bot, message, webhook_id = nil, webhook_generation = nil, delivery_id = nil)
    return unless webhook_id && webhook_generation && delivery_id

    bot.deliver_webhook(message, webhook_id:, webhook_generation:, delivery_id:)
  end
end
