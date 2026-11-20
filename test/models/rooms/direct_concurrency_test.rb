require "test_helper"

class Rooms::DirectConcurrencyTest < ActiveSupport::TestCase
  # Each request on its own database connection, as two Puma threads or workers are.
  self.use_transactional_tests = false

  setup do
    @pair = [ users(:jason), users(:jz) ]
    @last_room_id = Room.maximum(:id)
  end

  teardown do
    Room.where("id > ?", @last_room_id).destroy_all
  end

  test "two requests at once for the same pair get the same room" do
    Current.user = @pair.first
    other_request = nil

    assert_difference -> { Rooms::Direct.count }, +1 do
      # The other request runs just after this one has looked for the room and before it creates one.
      first = after_looking_for_the_room do
        other_request = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            Current.user = @pair.second
            Rooms::Direct.find_or_create_for(User.where(id: @pair.reverse))
          end
        end
        other_request.join(0.5)
      end

      assert_equal first, other_request.value
    end
  end

  private
    def after_looking_for_the_room(&block)
      looking = Thread.current
      called = false
      callback = ->(*, payload) do
        if Thread.current == looking && !called && payload[:name] == "Rooms::Direct Load"
          called = true
          block.call
        end
      end

      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
        Rooms::Direct.find_or_create_for(User.where(id: @pair))
      end
    end
end
