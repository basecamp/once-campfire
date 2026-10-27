require "test_helper"

class MembershipTest < ActiveSupport::TestCase
  setup do
    @membership = memberships(:david_watercooler)
  end

  test "connected scope" do
    @membership.connected
    assert Membership.connected.exists?(@membership.id)

    @membership.disconnected
    assert_not Membership.connected.exists?(@membership.id)

    travel_to Membership::Connectable::CONNECTION_TTL.from_now + 1
    assert_not Membership.connected.exists?(@membership.id)
  end

  test "disconnected scope" do
    @membership.disconnected
    assert Membership.disconnected.exists?(@membership.id)

    @membership.connected
    assert_not Membership.disconnected.exists?(@membership.id)

    travel_to Membership::Connectable::CONNECTION_TTL.from_now + 1
    assert Membership.disconnected.exists?(@membership.id)
  end

  test "connected? is false when connection is stale" do
    @membership.connected
    travel_to Membership::Connectable::CONNECTION_TTL.from_now + 1
    assert_not @membership.connected?
  end

  test "connecting" do
    @membership.connected
    assert @membership.connected?
    assert_equal 1, @membership.connections

    @membership.connected
    assert_equal 2, @membership.connections
  end

  test "connecting resets stale connection count" do
    2.times { @membership.connected }
    assert_equal 2, @membership.connections

    travel_to Membership::Connectable::CONNECTION_TTL.from_now + 1
    @membership.connected
    assert_equal 1, @membership.connections
  end

  test "disconnecting" do
    2.times { @membership.connected }

    @membership.disconnected
    assert @membership.connected?
    assert_equal 1, @membership.connections

    @membership.disconnected
    assert_not @membership.connected?
    assert_equal 0, @membership.connections
  end

  test "disconnecting resets stale connection count" do
    2.times { @membership.connected }
    assert_equal 2, @membership.connections

    travel_to Membership::Connectable::CONNECTION_TTL.from_now + 1
    @membership.disconnected
    assert_equal 0, @membership.connections
  end

  test "connections that open together each count" do
    first, second = 2.times.map { Membership.find(@membership.id) }

    first.present
    second.present

    assert_equal 2, @membership.reload.connections
  end

  test "connections that close together leave the member disconnected" do
    2.times { Membership.find(@membership.id).present }
    first, second = 2.times.map { Membership.find(@membership.id) }

    first.disconnected
    second.disconnected

    assert_not @membership.reload.connected?
    assert_equal 0, @membership.connections
  end

  test "refreshing a stale connection keeps the connections opened since" do
    2.times { @membership.connected }
    travel_to Membership::Connectable::CONNECTION_TTL.from_now + 1
    refreshing = Membership.find(@membership.id)
    2.times { Membership.find(@membership.id).present }

    refreshing.refresh_connection

    assert_equal 2, @membership.reload.connections
  end

  test "refreshing the connection" do
    @membership.connected

    travel_to Membership::Connectable::CONNECTION_TTL.from_now + 1
    assert_not @membership.connected?

    @membership.refresh_connection
    assert @membership.connected?
  end

  test "removing a membership resets the user's connections" do
    @membership.user.expects :reset_remote_connections

    @membership.destroy
  end
end
