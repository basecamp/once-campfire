class Room::DestroyJob < ApplicationJob
  discard_on ActiveJob::DeserializationError

  def perform(room, former_member_ids)
    room.reset_remote_connections_of(former_member_ids)
    room.destroy_one_message_at_a_time
  end
end
