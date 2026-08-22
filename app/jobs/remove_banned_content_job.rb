class RemoveBannedContentJob < ApplicationJob
  def perform(*arguments)
    if arguments.length == 1 && arguments.first.is_a?(User)
      legacy_intent_for(arguments.first)&.dispatch_safely || false
    elsif arguments.length == 2 && arguments.first.is_a?(Integer) && arguments.second.is_a?(String)
      BanCleanupIntent.find_by(id: arguments.first)&.perform!(arguments.second) || false
    else
      false
    end
  rescue ReliableWork::RetryScheduled => error
    Rails.logger.error(
      "Ban cleanup scheduled for retry intent_id=#{arguments.first.inspect} error=#{error.class.name}"
    )
    false
  end

  private
    def legacy_intent_for(user)
      User.transaction do
        current_user = User.lock.find_by(id: user.id)
        next unless current_user&.banned? && current_user.ban_cleanup_generation == 1

        BanCleanupIntent.create_or_find_by!(user: current_user, generation: 1)
      end
    end
end
