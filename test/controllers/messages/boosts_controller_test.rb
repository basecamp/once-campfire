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

  test "quick boost controls submit their displayed reaction to the message" do
    get room_url(@message.room)
    assert_select "##{dom_id(@message)} .quick-boosts", count: 0
    forms = message_menu_for(@message).css(".quick-boosts form")
    assert_equal EmojiHelper::REACTIONS.size, forms.size
    forms.each do |form|
      assert_equal "post", form["method"]
      assert_equal message_boosts_path(@message), form["action"]
      assert_equal dom_id(@message, :boosting), form["data-turbo-frame"]
      assert_equal "popup#close", form["data-action"]
      input = form.at_css('input[name="boost[content]"]')
      button = form.at_css('button[type="submit"]')
      assert_equal input["value"], button["data-emoji"]
      assert_equal EmojiHelper::REACTIONS.fetch(input["value"]), button["title"]
      assert_nil form.at_css('input[name="authenticity_token"]')
    end

    form = forms.first
    reaction = form.at_css('input[name="boost[content]"]')["value"]
    assert_difference -> { @message.boosts.count }, 1 do
      post form["action"], params: { boost: { content: reaction } }, headers: {
        "Sec-Fetch-Site" => "same-origin", "Origin" => "http://www.example.com" }
      assert_redirected_to message_boosts_url(@message)
    end
    assert_equal reaction, @message.boosts.order(:id).last.content
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
