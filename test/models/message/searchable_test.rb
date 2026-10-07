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

  test "a new attachment replaces the old file name in the index" do
    message = rooms(:designers).messages.create! attachment: fixture_file_upload("moon.jpg", "image/jpeg"), client_message_id: "moon", creator: users(:david)

    Message.find(message.id).update! attachment: fixture_file_upload("pixel.bmp", "image/bmp")
    assert_equal [ message ], rooms(:designers).messages.search("pixel")
    assert_equal [], rooms(:designers).messages.search("moon")
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

  test "bounded search keeps older reachable hits behind inaccessible matches" do
    accessible = rooms(:designers).messages.create! body: "bounded sparse needle", creator: users(:david)
    private_room = Room.create! name: "Private search history", type: "Rooms::Closed", creator: users(:jason)
    now = Time.current
    records = 1100.times.map do |i|
      { room_id: private_room.id, creator_id: users(:jason).id, client_message_id: "private-#{i}", created_at: now, updated_at: now }
    end
    ids = Message.insert_all!(records, returning: %w[id]).rows.flatten
    ids.each do |id|
      Message.connection.execute Message.sanitize_sql([ "INSERT INTO message_search_index(rowid,body) VALUES (?,?)", id, "bounded sparse needle" ])
    end
    assert_equal [ accessible.id ], Message.search_reachable(users(:david), "bounded sparse").map(&:id)
    rooms(:designers).memberships.where(user: users(:david)).delete_all
    assert_empty Message.search_reachable(users(:david), "bounded sparse")
  end

  test "rich text body is converted to plain text for indexing" do
    message = rooms(:designers).messages.create! body: "<span>My hovercraft is full of eels</span>", client_message_id: "earth", creator: users(:david)

    assert_equal [], rooms(:designers).messages.search("span")
    assert_equal [ message ], rooms(:designers).messages.search("eel")
  end
end
