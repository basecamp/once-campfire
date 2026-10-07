require "test_helper"

class Room::MessagesCountTest < ActiveSupport::TestCase
  setup do
    @room = rooms(:designers)
    @other_room = rooms(:pets)
  end

  test "fixture rooms start with an accurate messages_count" do
    [ rooms(:watercooler), rooms(:designers), rooms(:bender_and_kevin) ].each do |room|
      assert_equal room.messages.count, room.messages_count, "#{room.name || room.id} fixture count"
    end
  end

  test "ActiveRecord create and destroy adjust the counter once" do
    assert_difference -> { @room.reload.messages_count }, +1 do
      assert_difference -> { @room.messages.count }, +1 do
        @room.messages.create!(creator: users(:jason), body: "Hello", client_message_id: "count-ar-create")
      end
    end

    assert_equal @room.messages.count, @room.reload.messages_count

    assert_difference -> { @room.reload.messages_count }, -1 do
      assert_difference -> { @room.messages.count }, -1 do
        @room.messages.order(:id).last.destroy
      end
    end

    assert_equal @room.messages.count, @room.reload.messages_count
  end

  test "bulk insert_all and delete_all keep the counter in step" do
    rows = Array.new(3) do |i|
      {
        room_id: @room.id,
        creator_id: users(:david).id,
        client_message_id: "count-bulk-#{i}",
        created_at: Time.current,
        updated_at: Time.current
      }
    end

    assert_difference -> { @room.reload.messages_count }, +3 do
      Message.insert_all!(rows)
    end

    assert_equal @room.messages.count, @room.reload.messages_count

    assert_difference -> { @room.reload.messages_count }, -3 do
      @room.messages.where(client_message_id: rows.map { it[:client_message_id] }).delete_all
    end

    assert_equal @room.messages.count, @room.reload.messages_count
  end

  test "rolled back writes leave the counter unchanged" do
    before = @room.reload.messages_count

    Message.transaction do
      @room.messages.create!(creator: users(:jason), body: "Nope", client_message_id: "count-rollback")
      raise ActiveRecord::Rollback
    end

    assert_equal before, @room.reload.messages_count
    assert_nil Message.find_by(client_message_id: "count-rollback")
  end

  test "moving a message between rooms moves the counter" do
    message = @room.messages.create!(creator: users(:jason), body: "Move me", client_message_id: "count-move")

    assert_difference -> { @room.reload.messages_count }, -1 do
      assert_difference -> { @other_room.reload.messages_count }, +1 do
        message.update!(room: @other_room)
      end
    end

    assert_equal @room.messages.count, @room.reload.messages_count
    assert_equal @other_room.messages.count, @other_room.reload.messages_count
  end

  test "Message does not declare an ActiveRecord counter_cache" do
    reflection = Message.reflect_on_association(:room)
    assert_not reflection.counter_cache_column
  end
end
