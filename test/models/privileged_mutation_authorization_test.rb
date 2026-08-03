require "test_helper"

class PrivilegedMutationAuthorizationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    User.any_instance.stubs(:disconnect_remote_connections)
    clear_enqueued_jobs
  end

  test "administrator demotion committing first prevents ban" do
    actor = users(:jason)
    target = users(:kevin)

    error = race_after_demotion(actor) { target.ban_by!(actor:) }

    assert_kind_of User::AuthorizationError, error
    assert target.reload.active?
    assert_empty target.ban_cleanup_intents
  end

  test "administrator demotion committing first prevents account mutations" do
    actor = users(:jason)
    account = accounts(:signal)
    original_join_code = account.join_code

    error = race_after_demotion(actor) { account.reset_join_code!(actor:) }
    assert_kind_of User::AuthorizationError, error
    assert_equal original_join_code, account.reload.join_code

    actor.update!(role: :administrator)
    error = race_after_demotion(actor) do
      account.update_custom_styles!({ custom_styles: "body { display: none; }" }, actor:)
    end
    assert_kind_of User::AuthorizationError, error
    assert_nil account.reload.custom_styles
  end

  test "administrator demotion committing first prevents room conversion" do
    actor = users(:jason)
    room = rooms(:pets)

    error = race_after_demotion(actor) do
      room.update_as_closed!({ name: "Unauthorized" }, user_ids: [ users(:david).id ], actor:)
    end

    assert_kind_of User::AuthorizationError, error
    assert_equal "Rooms::Open", room.reload.type
    assert_not_equal "Unauthorized", room.name
  end

  test "administrator demotion committing first prevents room deletion" do
    actor = users(:jason)
    room = rooms(:pets)

    error = race_after_demotion(actor) { room.destroy_by!(actor:) }

    assert_kind_of User::AuthorizationError, error
    assert Room.exists?(room.id)
  end

  test "administrator demotion committing first prevents bot mutation" do
    actor = users(:jason)
    bot = users(:bender)

    error = race_after_demotion(actor) { bot.update_bot!({ name: "Unauthorized" }, actor:) }

    assert_kind_of User::AuthorizationError, error
    assert_not_equal "Unauthorized", bot.reload.name
  end

  test "a creator without current membership cannot administer a room" do
    actor = users(:jz)
    open_room = Rooms::Closed.create!(name: "Former creator open", creator: actor)
    closed_room = Rooms::Closed.create!(name: "Former creator closed", creator: actor)
    destroy_room = Rooms::Closed.create!(name: "Former creator destroy", creator: actor)

    assert_raises(User::AuthorizationError) { open_room.update_as_open!({ name: "Unauthorized" }, actor:) }
    assert_raises(User::AuthorizationError) do
      closed_room.update_as_closed!({ name: "Unauthorized" }, user_ids: [], actor:)
    end
    assert_raises(User::AuthorizationError) { destroy_room.destroy_by!(actor:) }

    assert Room.exists?(open_room.id)
    assert Room.exists?(closed_room.id)
    assert Room.exists?(destroy_room.id)
  end

  test "an administrator with current membership can administer a room" do
    actor = users(:jason)
    creator = users(:david)
    rename_room = Rooms::Closed.create!(name: "Administrator rename", creator:)
    convert_room = Rooms::Closed.create!(name: "Administrator convert", creator:)
    destroy_room = Rooms::Closed.create!(name: "Administrator destroy", creator:)
    [ rename_room, convert_room, destroy_room ].each { _1.memberships.create!(user: actor) }

    rename_room.update_as_closed!({ name: "Renamed" }, user_ids: [ actor.id ], actor:)
    convert_room.becomes!(Rooms::Open).update_as_open!({ name: "Converted" }, actor:)
    destroy_room.destroy_by!(actor:)

    assert_equal "Renamed", rename_room.reload.name
    assert Room.find(convert_room.id).open?
    assert_not Room.exists?(destroy_room.id)
  end

  test "an administrator without current membership cannot administer a room" do
    actor = users(:jason)
    creator = users(:david)
    rename_room = Rooms::Closed.create!(name: "Administrator rename", creator:)
    convert_room = Rooms::Closed.create!(name: "Administrator convert", creator:)
    destroy_room = Rooms::Closed.create!(name: "Administrator destroy", creator:)

    assert_raises(User::AuthorizationError) do
      rename_room.update_as_closed!({ name: "Unauthorized" }, user_ids: [ actor.id ], actor:)
    end
    assert_raises(User::AuthorizationError) do
      convert_room.update_as_open!({ name: "Unauthorized" }, actor:)
    end
    assert_raises(User::AuthorizationError) { destroy_room.destroy_by!(actor:) }

    assert_equal "Administrator rename", rename_room.reload.name
    assert_equal "Administrator convert", convert_room.reload.name
    assert Room.exists?(destroy_room.id)
  end

  test "administrator membership revocation committing first prevents room rename" do
    actor = users(:jason)
    room = Rooms::Closed.create!(name: "Administrator room", creator: users(:david))
    room.memberships.create!(user: actor)

    error = race_after_membership_revocation(actor, room) do
      Room.find(room.id).update_as_closed!({ name: "Unauthorized" }, user_ids: [], actor: User.find(actor.id))
    end

    assert_kind_of User::AuthorizationError, error
    assert_equal "Administrator room", room.reload.name
  end

  test "administrator membership revocation committing first prevents room conversion" do
    actor = users(:jason)
    room = Rooms::Closed.create!(name: "Administrator room", creator: users(:david))
    room.memberships.create!(user: actor)

    error = race_after_membership_revocation(actor, room) do
      Room.find(room.id).becomes!(Rooms::Open).update_as_open!({}, actor: User.find(actor.id))
    end

    assert_kind_of User::AuthorizationError, error
    assert Room.find(room.id).closed?
  end

  test "administrator membership revocation committing first prevents room deletion" do
    actor = users(:jason)
    room = Rooms::Closed.create!(name: "Administrator room", creator: users(:david))
    room.memberships.create!(user: actor)

    error = race_after_membership_revocation(actor, room) do
      Room.find(room.id).destroy_by!(actor: User.find(actor.id))
    end

    assert_kind_of User::AuthorizationError, error
    assert Room.exists?(room.id)
  end

  test "creator membership revocation committing first prevents room conversion" do
    actor = users(:jz)
    room = Rooms::Closed.create!(name: "Creator room", creator: actor)
    room.memberships.create!(user: actor)

    error = race_after_membership_revocation(actor, room) do
      Room.find(room.id).becomes!(Rooms::Open).update_as_open!({ name: "Unauthorized" }, actor: User.find(actor.id))
    end

    assert_kind_of User::AuthorizationError, error
    assert_equal "Rooms::Closed", room.reload.type
    assert_equal "Creator room", room.name
  end

  private
    def race_after_membership_revocation(actor, room, &mutation)
      membership = room.memberships.find_by!(user: actor)
      ready = Queue.new
      release = Queue.new
      result = Queue.new
      revocation = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Membership.transaction do
            Membership.find(membership.id).destroy!
            ready << true
            release.pop
          end
        end
      end
      ready.pop
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          mutation.call
          result << true
        rescue StandardError => error
          result << error
        end
      end

      assert_predicate worker, :alive?
      release << true
      revocation.value
      worker.join
      result.pop
    ensure
      release << true if revocation&.alive?
      revocation&.join(2)
      worker&.join(2)
    end

    def race_after_demotion(actor, &mutation)
      ready = Queue.new
      release = Queue.new
      result = Queue.new
      demotion = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          User.transaction do
            User.find(actor.id).update!(role: :member)
            ready << true
            release.pop
          end
        end
      end
      ready.pop
      worker = Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          mutation.call
          result << true
        rescue StandardError => error
          result << error
        end
      end

      assert_predicate worker, :alive?
      release << true
      demotion.value
      worker.join
      result.pop
    ensure
      release << true if demotion&.alive?
      demotion&.join(2)
      worker&.join(2)
    end
end
