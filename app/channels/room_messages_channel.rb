# Authorizes the room message stream when the subscription is made, so that revoking a
# membership actually stops delivery.
#
# Turbo's stock channel verifies only the signature on the stream name. That name carries
# no expiry and no binding to a user, so one harvested while a member keeps working after
# the membership is gone. Reconnecting makes it worse rather than better: revoking a
# membership disconnects the user with reconnect: true, and the client then replays its
# subscriptions on the fresh socket.
#
# The room is derived from the verified stream name rather than taken as a parameter, so
# there's nothing for a subscriber to point somewhere else. The subscriber also doesn't
# get to choose the channel: Turbo::StreamsChannel turns these stream names away, so this
# is the only way onto them. See config/initializers/turbo_streams_authorization.rb.
class RoomMessagesChannel < ApplicationCable::Channel
  extend  Turbo::Streams::StreamName
  include Turbo::Streams::StreamName::ClassMethods

  STREAM_SUFFIX = "messages"

  class << self
    # True for the stream names this channel exists to guard, whoever is asking.
    def guarded_stream?(stream_name)
      stream_name.to_s.split(":", 2).second == STREAM_SUFFIX
    end

    def subscribable_room(user, stream_name)
      gid_param, suffix = stream_name.to_s.split(":", 2)

      if suffix == STREAM_SUFFIX && room = room_from(gid_param)
        user.rooms.find_by(id: room.id)
      end
    end

    private
      def room_from(gid_param)
        GlobalID::Locator.locate gid_param, only: Room
      rescue ActiveRecord::RecordNotFound
        nil
      end
  end

  def subscribed
    if stream_name = authorized_stream_name
      stream_from stream_name
    else
      reject
    end
  end

  private
    def authorized_stream_name
      stream_name = verified_stream_name_from_params
      stream_name if stream_name.present? && self.class.subscribable_room(current_user, stream_name)
    end
end
