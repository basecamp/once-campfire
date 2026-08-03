class Room::MessagePusher
  attr_reader :room, :message

  def initialize(room:, message:)
    @room, @message = room, message
  end

  def push
    Rails.configuration.x.web_push_pool.queue(
      build_payload, Push::Subscription.where(id: recipient_ids), room:, message:
    )
  end

  def push_to(subscription_id)
    Rails.configuration.x.web_push_pool.queue(
      build_payload, Push::Subscription.where(id: subscription_id), room:, message:
    )
  end

  def recipient_ids
    push_subscriptions_for_users_involved_in_everything.ids |
      push_subscriptions_for_mentionable_users(message.mentionees).ids
  end

  private
    def build_payload
      {
        title: "New Campfire message",
        body: "Open Campfire to view it.",
        path: Rails.application.routes.url_helpers.root_path
      }
    end

    def push_subscriptions_for_users_involved_in_everything
      relevant_subscriptions.merge(Membership.involved_in_everything)
    end

    def push_subscriptions_for_mentionable_users(mentionees)
      relevant_subscriptions.merge(Membership.involved_in_mentions).where(user_id: mentionees.ids)
    end

    def relevant_subscriptions
      Push::Subscription
        .with_current_session
        .joins(user: :memberships)
        .merge(Membership.visible.disconnected.where(room: room).where.not(user: message.creator))
    end
end
