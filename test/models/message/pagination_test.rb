require "test_helper"

class Message::PaginationTest < ActiveSupport::TestCase
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
end
