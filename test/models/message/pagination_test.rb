require "test_helper"

class Message::PaginationTest < ActiveSupport::TestCase
  test "messages updated since a time are found through the room and update time index" do
    assert_match(/USING INDEX index_messages_on_room_id_and_updated_at \(room_id=\? AND updated_at>\?\)/, plan_of_page_updated_since)
  end

  test "messages updated since a time are the newest page of them, in creation order" do
    room = rooms(:watercooler)
    first, second, third = room.messages.ordered.first(3)

    travel 1.minute do
      [ third, first, second ].each(&:touch)

      stub_const(Message::Pagination, :PAGE_SIZE, 2) do
        assert_equal [ second, third ], room.messages.page_updated_since(30.seconds.ago).to_a
      end
    end
  end

  private
    def plan_of_page_updated_since
      statements = []
      callback = ->(*, payload) { statements << payload[:sql] if payload[:sql].start_with?(%(SELECT "messages")) }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        rooms(:watercooler).messages.page_updated_since(1.minute.ago)
      end

      Message.connection.select_rows("EXPLAIN QUERY PLAN #{statements.sole}").map(&:last).join(" | ")
    end
end
