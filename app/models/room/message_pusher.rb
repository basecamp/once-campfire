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
        body: excerpt,
        path: Rails.application.routes.url_helpers.room_path(room)
      }
    end

    def build_shared_payload
      {
        title: room.name,
        body: "#{message.creator.name}: #{excerpt}",
        path: Rails.application.routes.url_helpers.room_path(room)
      }
    end

    # The web-push gem won't encrypt a notification over 4 KB, so a long message used to notify no one. A notification
    # shows only the start of a message anyway.
    def excerpt
      message.plain_text_body.truncate(200, omission: "…")
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
