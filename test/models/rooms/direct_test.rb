require "test_helper"

class Rooms::DirectTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  test "create room for same users" do
    room = Rooms::Direct.find_or_create_for([ users(:david), users(:kevin) ], actor: users(:david))
    assert room.users.include?(users(:david))
    assert room.users.include?(users(:kevin))
    assert_not room.users.include?(users(:jason))
  end

  test "only one room will exist for the same users" do
    room1 = Rooms::Direct.find_or_create_for([ users(:david), users(:kevin) ], actor: users(:david))
    room2 = Rooms::Direct.find_or_create_for([ users(:kevin), users(:david) ], actor: users(:kevin))
    assert_equal room1, room2
  end

  test "default involvement for new users" do
    room = Rooms::Direct.find_or_create_for([ users(:david), users(:kevin) ], actor: users(:david))
    assert room.memberships.all? { |m| m.involved_in_everything? }
  end

  test "raw canonical room creation is prohibited" do
    room = Rooms::Direct.new(
      creator: users(:david),
      direct_participant_key: Rooms::Direct.participant_key_for([ users(:david).id, users(:jz).id ])
    )

    assert_not room.save
    assert_includes room.errors[:base], "direct rooms must be created with their canonical participants"
  end

  test "canonical participants cannot be inserted or removed" do
    room = Rooms::Direct.find_or_create_for([ users(:david), users(:jz) ], actor: users(:david))
    participant_ids = room.user_ids.sort

    assert_raises(Rooms::Direct::ParticipantMutationError) do
      room.memberships.create!(user: users(:jason))
    end
    assert_raises(Rooms::Direct::ParticipantMutationError) do
      room.memberships.grant_to(users(:jason))
    end
    assert_raises(Rooms::Direct::ParticipantMutationError) do
      room.memberships.find_by!(user: users(:david)).destroy!
    end
    assert_raises(Rooms::Direct::ParticipantMutationError) do
      room.memberships.revoke_from(users(:david))
    end
    assert_raises(Rooms::Direct::ParticipantMutationError) do
      room.memberships.delete_all
    end
    assert_raises(Rooms::Direct::ParticipantMutationError) do
      room.users.delete(users(:david))
    end
    assert_raises(Rooms::Direct::ParticipantMutationError) do
      room.user_ids = [ users(:david).id ]
    end
    assert_raises(Rooms::Direct::ParticipantMutationError) do
      room.memberships.find_by!(user: users(:david)).update!(user: users(:jason))
    end
    assert_not room.update(direct_participant_key: Rooms::Direct.participant_key_for([ users(:david).id ]))
    assert_includes room.errors[:direct_participant_key], "cannot be changed"

    assert_equal participant_ids, room.reload.user_ids.sort
    assert_equal Rooms::Direct.participant_key_for(participant_ids), room.direct_participant_key
  end

  test "direct room identity and type cannot change" do
    room = Rooms::Direct.find_or_create_for([ users(:david), users(:jz) ], actor: users(:david))
    original_key = room.direct_participant_key

    converted = room.becomes!(Rooms::Open)
    assert_not converted.save
    assert_includes converted.errors[:type], "cannot be changed for a direct room"

    room.reload
    assert_not room.update(direct_participant_key: "legacy:replacement")
    assert_includes room.errors[:direct_participant_key], "cannot be changed"
    assert room.reload.direct?
    assert_equal original_key, room.direct_participant_key
  end

  test "canonical lookup ignores preserved duplicate rooms" do
    participants = [ users(:david), users(:jz) ]
    canonical = Rooms::Direct.find_or_create_for(participants, actor: participants.first)
    duplicate_id = Room.insert!({
      type: "Rooms::Direct", creator_id: participants.first.id,
      direct_participant_key: "legacy:duplicate:#{canonical.direct_participant_key}",
      created_at: Time.current, updated_at: Time.current
    }).first.fetch("id")
    Membership.insert_all!(participants.map do |user|
      {
        room_id: duplicate_id, user_id: user.id, involvement: "everything",
        created_at: Time.current, updated_at: Time.current
      }
    end)
    duplicate = Rooms::Direct.find(duplicate_id)

    assert_equal canonical,
      Rooms::Direct.find_or_create_for(participants.reverse, actor: participants.last)
    assert_raises(Rooms::Direct::ParticipantMutationError) do
      duplicate.memberships.create!(user: users(:jason))
    end
    assert_not duplicate.becomes!(Rooms::Closed).save
    assert_equal participants.map(&:id).sort, duplicate.reload.user_ids.sort
  end

  test "whole room destruction removes canonical participant rows" do
    room = Rooms::Direct.find_or_create_for([ users(:david), users(:jz) ], actor: users(:david))
    membership_ids = room.membership_ids

    room.destroy!

    assert_not Room.exists?(room.id)
    assert_not Membership.where(id: membership_ids).exists?
  end

  test "concurrent canonical participant insertion and removal both fail closed" do
    room = Rooms::Direct.find_or_create_for([ users(:david), users(:jz) ], actor: users(:david))
    membership_id = room.memberships.find_by!(user: users(:david)).id
    barrier = Concurrent::CyclicBarrier.new(2)
    results = Queue.new
    operations = [
      -> { Room.find(room.id).memberships.create!(user: users(:jason)) },
      -> { Membership.find(membership_id).destroy! }
    ]

    threads = operations.map do |operation|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait
          operation.call
          results << true
        rescue StandardError => error
          results << error
        end
      end
    end
    threads.each(&:join)
    outcomes = 2.times.map { results.pop }

    assert outcomes.all? { _1.is_a?(Rooms::Direct::ParticipantMutationError) }, outcomes.inspect
    assert_equal [ users(:david).id, users(:jz).id ].sort, room.reload.user_ids.sort
    assert_equal Rooms::Direct.participant_key_for(room.user_ids), room.direct_participant_key
  end

  test "concurrent creation converges on one canonical room" do
    user_ids = [ users(:david).id, users(:jz).id ]
    participant_key = Rooms::Direct.participant_key_for(user_ids)
    barrier = Concurrent::CyclicBarrier.new(2)
    results = Queue.new

    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait
          room = Rooms::Direct.find_or_create_for(User.where(id: user_ids), actor: users(:david))
          results << room.id
        rescue StandardError => error
          results << error
        end
      end
    end
    threads.each(&:join)
    outcomes = 2.times.map { results.pop }

    assert_empty outcomes.grep(Exception), outcomes.inspect
    assert_equal 1, outcomes.uniq.size
    assert_equal 1, Rooms::Direct.where(direct_participant_key: participant_key).count
  end

  test "a ban committing first prevents stale direct room creation" do
    actor = users(:jz)
    user_ids = [ actor.id, users(:kevin).id ]
    ready = Queue.new
    release = Queue.new
    result = Queue.new
    User.any_instance.stubs(:disconnect_remote_connections)
    ban = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User.transaction do
          User.find(actor.id).ban_by! actor: users(:david)
          ready << true
          release.pop
        end
      end
    end
    ready.pop
    creation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Rooms::Direct.find_or_create_for(User.where(id: user_ids), actor: User.find(actor.id))
        result << true
      rescue StandardError => error
        result << error
      end
    end

    assert_predicate creation, :alive?
    release << true
    ban.value
    creation.join

    assert_kind_of User::AuthorizationError, result.pop
    assert_not Rooms::Direct.exists?(direct_participant_key: Rooms::Direct.participant_key_for(user_ids))
  ensure
    release << true if ban&.alive?
    ban&.join(2)
    creation&.join(2)
  end
end
