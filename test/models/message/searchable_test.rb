require "test_helper"

class Message::SearchableTest < ActiveSupport::TestCase
  test "message body is indexed and searchable" do
    message = rooms(:designers).messages.create! body: "My hovercraft is full of eels", client_message_id: "earth", creator: users(:david)
    assert_equal [ message ], rooms(:designers).messages.search("eel")

    message.update! body: "My hovercraft is full of sharks"
    assert_equal [ message ], rooms(:designers).messages.search("sharks")

    message.destroy!
    assert_equal [], rooms(:designers).messages.search("sharks")
  end

  test "search results are returned in message order" do
    messages = [ "first cat", "second cat", "third cat", "cat cat cat" ].map do |body|
      rooms(:designers).messages.create! body: body, client_message_id: body, creator: users(:david)
    end

    assert_equal messages, rooms(:designers).messages.search("cat")
  end

  test "the last page of matches holds the newest ones, read off the index without sorting every match" do
    messages = [ "first cat", "second cat", "third cat" ].map do |body|
      rooms(:designers).messages.create! body: body, client_message_id: body, creator: users(:david)
    end

    queries = []
    collect = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?("message_search_index") }
    page = ActiveSupport::Notifications.subscribed(collect, "sql.active_record") do
      rooms(:designers).messages.search("cat").last_page_of_matches(2)
    end

    assert_equal messages.last(2), page
    assert_no_match(/TEMP B-TREE/, Message.connection.select_rows("EXPLAIN QUERY PLAN #{queries.sole}").map(&:last).join(" | "))
  end

  test "rich text body is converted to plain text for indexing" do
    message = rooms(:designers).messages.create! body: "<span>My hovercraft is full of eels</span>", client_message_id: "earth", creator: users(:david)

    assert_equal [], rooms(:designers).messages.search("span")
    assert_equal [ message ], rooms(:designers).messages.search("eel")
  end
end
