require "test_helper"

class Messages::BoostsControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
    @message = messages(:first)
  end

  test "index wires the new boost link to the soft keyboard" do
    get message_boosts_url(@message)

    assert_response :success
    assert_select ".message__boost-inline a.boost__action[data-action='soft-keyboard#open']"
  end

  test "index looks up the boosters of all boosts at once" do
    @message.boosts.create! booster: users(:jason), content: "🎉"
    queries_with_two_boosts = count_queries { get message_boosts_url(@message) }

    boost = @message.boosts.create! booster: users(:kevin), content: "👀"
    assert_equal queries_with_two_boosts, count_queries { get message_boosts_url(@message) }
    assert_select "#" + dom_id(boost)
  end

  test "create" do
    assert_turbo_stream_broadcasts [ @message.room, :messages ], count: 1 do
      assert_difference -> { @message.boosts.count }, 1 do
        post message_boosts_url(@message, format: :turbo_stream), params: { boost: { content: "Morning!" } }
        assert_redirected_to message_boosts_url(@message)
      end
    end
  end

  test "destroy" do
    assert_turbo_stream_broadcasts [ @message.room, :messages ], count: 1 do
      assert_difference -> { @message.boosts.count }, -1 do
        delete message_boost_url(@message, boosts(:first), format: :turbo_stream)
        assert_response :success
      end
    end
  end

  private
    def count_queries(&block)
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      count
    end
end
