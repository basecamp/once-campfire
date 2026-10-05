require "test_helper"
require "active_record/testing/query_assertions"

class Message::SearchableTest < ActiveSupport::TestCase
  include ActionDispatch::TestProcess, ActiveRecord::Assertions::QueryAssertions

  test "message body is indexed and searchable" do
    message = rooms(:designers).messages.create! body: "My hovercraft is full of eels", client_message_id: "earth", creator: users(:david)
    assert_equal [ message ], rooms(:designers).messages.search("eel")

    message.update! body: "My hovercraft is full of sharks"
    assert_equal [ message ], rooms(:designers).messages.search("sharks")

    message.destroy!
    assert_equal [], rooms(:designers).messages.search("sharks")
  end

  test "boosting a message leaves the search index alone, whether or not its body is loaded" do
    attachment_message = rooms(:designers).messages.create! attachment: fixture_file_upload("moon.jpg", "image/jpeg"), client_message_id: "moon", creator: users(:david)

    [ messages(:first), Message.with_rich_text_body.find(messages(:first).id), Message.with_rich_text_body.find(attachment_message.id) ].each do |message|
      assert_no_queries_match(/message_search_index/) do
        message.boosts.create!(content: "🦞", booster: users(:jason)).destroy!
      end
    end
  end

  test "saving a new body replaces the old words in the index" do
    message = rooms(:designers).messages.create! body: "My hovercraft is full of eels", client_message_id: "earth", creator: users(:david)

    Message.find(message.id).update! body: "My hovercraft is full of sharks"
    assert_equal [ message ], rooms(:designers).messages.search("sharks")
    assert_equal [], rooms(:designers).messages.search("eels")

    Message.find(message.id).body.update! body: "My hovercraft is full of whales"
    assert_equal [ message ], rooms(:designers).messages.search("whales")
    assert_equal [], rooms(:designers).messages.search("sharks")
  end

  test "search results are returned in message order" do
    messages = [ "first cat", "second cat", "third cat", "cat cat cat" ].map do |body|
      rooms(:designers).messages.create! body: body, client_message_id: body, creator: users(:david)
    end

    assert_equal messages, rooms(:designers).messages.search("cat")
  end

  test "rich text body is converted to plain text for indexing" do
    message = rooms(:designers).messages.create! body: "<span>My hovercraft is full of eels</span>", client_message_id: "earth", creator: users(:david)

    assert_equal [], rooms(:designers).messages.search("span")
    assert_equal [ message ], rooms(:designers).messages.search("eel")
  end
end
