require "test_helper"

class RoomMutationAuthorizationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    @actor = users(:jason)
    @room = rooms(:designers)
    User.any_instance.stubs(:disconnect_remote_connections)
    sign_in @actor
  end

  test "membership revocation committing after room lookup prevents rename" do
    user_ids = @room.user_ids

    status = revoke_membership_before(:update_as_closed!) do
      put rooms_closed_url(@room), params: {
        room: { name: "Unauthorized" }, user_ids:
      }
      response.status
    end

    assert_equal 403, status
    assert_equal "Designers", @room.reload.name
    assert @room.closed?
  end

  test "membership revocation committing after room lookup prevents conversion" do
    status = revoke_membership_before(:update_as_open!) do
      put rooms_open_url(@room), params: { room: { name: "Unauthorized" } }
      response.status
    end

    assert_equal 403, status
    assert_equal "Designers", @room.reload.name
    assert @room.closed?
  end

  test "membership revocation committing after room lookup prevents deletion" do
    status = revoke_membership_before(:destroy_by!) do
      delete room_url(@room)
      response.status
    end

    assert_equal 403, status
    assert Room.exists?(@room.id)
  end

  private
    def revoke_membership_before(method)
      original = Room.instance_method(method)
      actor_id = @actor.id
      Room.send(:define_method, method) do |*arguments, **keywords, &block|
        Membership.find_by!(room_id: id, user_id: actor_id).destroy!
        original.bind_call(self, *arguments, **keywords, &block)
      end

      yield
    ensure
      Room.send(:define_method, method, original) if original
    end
end
