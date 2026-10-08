class Room::MessagePusher
  attr_reader :room, :message

  def initialize(room:, message:)
    @room, @message = room, message
  end

  def push
    subscriptions = push_subscriptions_for_users_involved_in_everything.or(push_subscriptions_for_mentionable_users(message.mentionees))
    if subscriptions.exists?
      Rails.configuration.x.web_push_pool.queue(build_payload, subscriptions)
    end
  end

  private
    def build_payload
      if room.direct?
        build_direct_payload
      else
        build_shared_payload
      end
    end

    def build_direct_payload
      {
        title: message.creator.name,
        body: message.plain_text_body,
        path: Rails.application.routes.url_helpers.room_path(room)
      }
    end

    def build_shared_payload
      {
        title: room.name,
        body: "#{message.creator.name}: #{message.plain_text_body}",
        path: Rails.application.routes.url_helpers.room_path(room)
      }
    end

    def push_subscriptions_for_users_involved_in_everything
      relevant_subscriptions.merge(Membership.involved_in_everything)
    end

    def push_subscriptions_for_mentionable_users(mentionees)
      relevant_subscriptions.merge(Membership.involved_in_mentions).where(user_id: mentionees.ids)
    end

    # Banning keeps the user's subscriptions, so that unbanning brings their notifications back,
    # but nobody who can't sign in should be sent what's said in their rooms meanwhile.
    def relevant_subscriptions
      Push::Subscription
        .joins(user: :memberships)
        .merge(User.active)
        .merge(Membership.visible.disconnected.where(room: room).where.not(user_id: message.creator_id))
    end
end
