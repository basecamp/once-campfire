module Message::Broadcasts
  extend ActiveSupport::Concern

  class_methods do
    def broadcast_destroy(room, client_message_id)
      snapshot = new(room_id: room.id, client_message_id:)
      snapshot.broadcast_remove_to room, :messages
    end
  end

  def broadcast_create
    broadcast_append_to room, :messages, target: [ room, :messages ]
  end

  def broadcast_update
    broadcast_replace_to room, :messages, target: [ self, :presentation ],
      partial: "messages/presentation", attributes: { maintain_scroll: true }
  end

  def broadcast_remove
    broadcast_remove_to room, :messages
  end
end
