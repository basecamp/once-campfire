require "test_helper"

class RoomTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  test "grant membership to user" do
    rooms(:watercooler).memberships.grant_to(users(:kevin))
    assert rooms(:watercooler).users.include?(users(:kevin))
  end

  test "revoke membership from user" do
    rooms(:watercooler).memberships.revoke_from(users(:david))
    assert_not rooms(:watercooler).users.include?(users(:david))
  end

  test "revise memberships" do
    rooms(:watercooler).memberships.revise(granted: users(:kevin), revoked: users(:david))
    assert rooms(:watercooler).users.include?(users(:kevin))
    assert_not rooms(:watercooler).users.include?(users(:david))
  end

  test "create for users by giving them immediate membership" do
    room = Rooms::Closed.create_for({ name: "Hello!", creator: users(:david) }, users: [ users(:kevin), users(:david) ])
    assert room.users.include?(users(:kevin))
    assert room.users.include?(users(:david))
  end

  test "a new message marks unread the members who had read the room and leaves the unread ones as they were" do
    room = rooms(:watercooler)
    reader = memberships(:jason_watercooler)
    behind = memberships(:bender_watercooler)
    behind.update_columns unread_at: 1.hour.ago, updated_at: 1.hour.ago
    behind_before = behind.reload.attributes.slice("unread_at", "updated_at")

    message = room.messages.create! creator: users(:david), body: "Hello", client_message_id: "unread-once"

    assert_equal message.created_at, reader.reload.unread_at
    assert_equal behind_before, behind.reload.attributes.slice("unread_at", "updated_at")
    assert_not memberships(:david_watercooler).reload.unread?
  end

  test "type" do
    assert Rooms::Open.new.open?
    assert_not Rooms::Open.new.direct?
    assert Rooms::Direct.new.direct?
    assert Rooms::Closed.new.closed?
  end

  test "an open room destroyed later lets no one in who joins the account before the job runs" do
    room = rooms(:pets)

    room.destroy_later
    newcomer = User.create!(name: "Newcomer", email_address: "newcomer@example.com", password: "secret123456")

    assert_not newcomer.memberships.exists?(room_id: room.id)
    perform_enqueued_jobs only: Room::DestroyJob
    assert_not Room.exists?(room.id)
  end

  test "a room destroyed later resets the connections of its former members, as revoking their memberships would" do
    room = rooms(:designers)
    former_members = room.users.to_a
    assert former_members.many?

    room.destroy_later
    perform_enqueued_jobs only: Room::DestroyJob

    former_members.each do |member|
      assert_broadcast_on "action_cable/#{member.to_gid_param}", { type: "disconnect", reconnect: true }
    end
  end

  test "destroying one message at a time leaves nothing of the room behind" do
    room = rooms(:designers)
    searchable = room.messages.create!(body: "Kept in the search index", creator: users(:david))
    searchable.attachment.attach io: StringIO.new("hello"), filename: "hello.txt", content_type: "text/plain"
    message_ids = room.messages.ids
    assert Boost.where(message_id: message_ids).exists?
    assert_equal 1, search_index_rows(searchable)

    room.destroy_one_message_at_a_time

    assert_not Room.exists?(room.id)
    assert_empty Message.where(id: message_ids)
    assert_empty Boost.where(message_id: message_ids)
    assert_empty ActionText::RichText.where(record_type: "Message", record_id: message_ids)
    assert_empty ActiveStorage::Attachment.where(record_type: "Message", record_id: message_ids)
    assert_enqueued_jobs 1, only: ActiveStorage::PurgeJob
    assert_equal 0, search_index_rows(searchable)
  end

  test "each message is destroyed in its own transaction, so other writes get through in between" do
    room = rooms(:designers)
    messages = room.messages.count
    transactions = 0
    count_transactions = ->(*, payload) { transactions += 1 if payload[:sql].start_with?("RELEASE SAVEPOINT") }

    ActiveSupport::Notifications.subscribed(count_transactions, "sql.active_record") { room.destroy_one_message_at_a_time }

    assert_equal messages + 1, transactions
  end

  test "default involvement for new users" do
    room = Rooms::Closed.create_for({ name: "Hello!", creator: users(:david) }, users: [ users(:kevin), users(:david) ])
    assert room.memberships.all? { |m| m.involved_in_mentions? }
  end

  private
    def search_index_rows(message)
      Message.connection.select_value("select count(*) from message_search_index where rowid = #{message.id}")
    end
end
