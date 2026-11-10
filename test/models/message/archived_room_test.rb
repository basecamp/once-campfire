require "test_helper"

class Message::ArchivedRoomTest < ActiveSupport::TestCase
  test "messages cannot be created in archived rooms" do
    room = rooms(:designers)
    room.update!(archived_at: Time.current)

    message = room.messages.new(creator: users(:david), body: "Still talking?", client_message_id: "archived-1")

    assert_not message.valid?
    assert_includes message.errors[:room], "is archived"
  end
end
