class Room::DestroyJob < ApplicationJob
  discard_on ActiveJob::DeserializationError

  def perform(room)
    room.destroy_one_message_at_a_time
  end
end
