require "test_helper"

class RoomMessagesChannelTest < ActionCable::Channel::TestCase
  tests RoomMessagesChannel

  setup do
    @room = rooms(:designers)
    @signed_stream_name = Turbo::StreamsChannel.signed_stream_name [ @room, :messages ]
  end

  test "a member may subscribe to a room's message stream" do
    stub_connection(current_user: users(:kevin))

    subscribe signed_stream_name: @signed_stream_name

    assert subscription.confirmed?
    assert_has_stream Turbo.signed_stream_verifier.verified(@signed_stream_name)
  end

  test "a user who was never a member may not subscribe" do
    stub_connection(current_user: users(:bender))

    subscribe signed_stream_name: @signed_stream_name

    assert subscription.rejected?
  end

  test "a revoked member may not re-subscribe with a stream name harvested while a member" do
    stub_connection(current_user: users(:kevin))

    subscribe signed_stream_name: @signed_stream_name
    assert subscription.confirmed?, "kevin must start out able to subscribe"

    @room.memberships.revoke_from users(:kevin)

    subscribe signed_stream_name: @signed_stream_name

    assert subscription.rejected?
  end

  test "an unsigned stream name is rejected" do
    stub_connection(current_user: users(:kevin))

    subscribe signed_stream_name: Turbo.signed_stream_verifier.verified(@signed_stream_name)

    assert subscription.rejected?
  end

  test "a missing stream name is rejected" do
    stub_connection(current_user: users(:kevin))

    subscribe

    assert subscription.rejected?
  end

  test "a validly signed stream name for another room the user isn't in is rejected" do
    stub_connection(current_user: users(:bender))

    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name([ rooms(:hq), :messages ])

    assert subscription.rejected?
  end
end

class RoomMessagesViaStockTurboChannelTest < ActionCable::Channel::TestCase
  tests Turbo::StreamsChannel

  # The subscriber picks the channel, so the stock channel has to turn these names away
  # too. Otherwise a revoked member just names Turbo::StreamsChannel instead.
  test "the stock turbo channel refuses to serve a room message stream" do
    stub_connection(current_user: users(:kevin))

    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name([ rooms(:designers), :messages ])

    assert subscription.rejected?
  end

  test "the stock turbo channel still serves the room list stream" do
    stub_connection(current_user: users(:kevin))

    subscribe signed_stream_name: Turbo::StreamsChannel.signed_stream_name([ :rooms ])

    assert subscription.confirmed?
  end
end
