class Bot::ActionWebhookJob < ApplicationJob
  retry_on Webhook::DeliveryError, wait: :polynomially_longer, attempts: 5
  discard_on ActiveJob::DeserializationError

  def perform(bot, message, user, value, selected, event_id:)
    bot.deliver_action_webhook(message, user, value, selected, event_id: event_id)
  end
end
