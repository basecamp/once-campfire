class MessageEffectJob < ApplicationJob
  def perform(effect_id, lease_token)
    Message::Effect.find_by(id: effect_id)&.perform!(lease_token)
  rescue ReliableWork::RetryScheduled => error
    Rails.logger.error(
      "Message effect scheduled for retry effect_id=#{effect_id} error=#{error.class.name}"
    )
    false
  end
end
