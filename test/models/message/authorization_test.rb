require "test_helper"

class Message::AuthorizationTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @room = rooms(:hq)
    @creator = users(:kevin)
    @membership = memberships(:kevin_hq)
    User.any_instance.stubs(:disconnect_remote_connections)
    clear_enqueued_jobs
  end

  test "a ban that commits first prevents message insertion" do
    ready = Queue.new
    release = Queue.new
    result = Queue.new
    ban = hold_transaction(ready, release) do
      User.find(@creator.id).ban_by! actor: users(:david)
    end
    ready.pop
    insertion = run_in_thread(result) { create_message("ban-first") }

    assert_predicate insertion, :alive?
    release << true
    ban.value
    insertion.join

    assert_kind_of User::AuthorizationError, result.pop
    assert_not @room.messages.exists?(client_message_id: "ban-first")
  ensure
    release << true if ban&.alive?
    ban&.join(2)
    insertion&.join(2)
  end

  test "an insertion that commits first is ordered before the ban" do
    ready = Queue.new
    release = Queue.new
    result = Queue.new
    insertion = hold_transaction(ready, release) do
      result << create_message("insert-before-ban").id
    end
    ready.pop
    ban_result = Queue.new
    ban = run_in_thread(ban_result) do
      User.find(@creator.id).ban_by! actor: users(:david)
    end

    assert_predicate ban, :alive?
    release << true
    insertion.value
    ban.join

    message_id = result.pop
    assert_kind_of Integer, message_id
    assert Message.exists?(message_id)
    assert @creator.reload.banned?
    assert_equal true, ban_result.pop
  ensure
    release << true if insertion&.alive?
    insertion&.join(2)
    ban&.join(2)
  end

  test "membership revocation that commits first prevents message insertion" do
    ready = Queue.new
    release = Queue.new
    result = Queue.new
    revocation = hold_transaction(ready, release) { Membership.find(@membership.id).destroy! }
    ready.pop
    insertion = run_in_thread(result) { create_message("revoke-first") }

    assert_predicate insertion, :alive?
    release << true
    revocation.value
    insertion.join

    assert_kind_of User::AuthorizationError, result.pop
    assert_not @room.messages.exists?(client_message_id: "revoke-first")
  ensure
    release << true if revocation&.alive?
    revocation&.join(2)
    insertion&.join(2)
  end

  test "an insertion that commits first is ordered before membership revocation" do
    ready = Queue.new
    release = Queue.new
    result = Queue.new
    insertion = hold_transaction(ready, release) do
      result << create_message("insert-before-revoke").id
    end
    ready.pop
    revocation_result = Queue.new
    revocation = run_in_thread(revocation_result) { Membership.find(@membership.id).destroy! }

    assert_predicate revocation, :alive?
    release << true
    insertion.value
    revocation.join

    message_id = result.pop
    assert Message.exists?(message_id)
    assert_not Membership.exists?(@membership.id)
    assert_equal true, revocation_result.pop
  ensure
    release << true if insertion&.alive?
    insertion&.join(2)
    revocation&.join(2)
  end

  test "membership revocation that commits first prevents a message update" do
    message = create_message("update-after-revoke")
    ready = Queue.new
    release = Queue.new
    result = Queue.new
    revocation = hold_transaction(ready, release) { Membership.find(@membership.id).destroy! }
    ready.pop
    update = run_in_thread(result) do
      message.update_with_broadcast!({ body: "unauthorized update" }, actor: @creator)
    end

    assert_predicate update, :alive?
    release << true
    revocation.value
    update.join

    assert_kind_of User::AuthorizationError, result.pop
    assert_equal "authorized", message.reload.plain_text_body
  ensure
    release << true if revocation&.alive?
    revocation&.join(2)
    update&.join(2)
  end

  test "a ban that commits first prevents a message destroy" do
    message = create_message("destroy-after-ban")
    ready = Queue.new
    release = Queue.new
    result = Queue.new
    ban = hold_transaction(ready, release) do
      User.find(@creator.id).ban_by! actor: users(:david)
    end
    ready.pop
    destroy = run_in_thread(result) { message.destroy_with_broadcast!(actor: @creator) }

    assert_predicate destroy, :alive?
    release << true
    ban.value
    destroy.join

    assert_kind_of User::AuthorizationError, result.pop
    assert Message.exists?(message.id)
  ensure
    release << true if ban&.alive?
    ban&.join(2)
    destroy&.join(2)
  end

  private
    def create_message(client_message_id)
      @room.messages.create!(creator: @creator, body: "authorized", client_message_id:).tap do
        clear_enqueued_jobs
      end
    end

    def hold_transaction(ready, release, &operation)
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          ActiveRecord::Base.transaction do
            operation.call
            ready << true
            release.pop
          end
        end
      end
    end

    def run_in_thread(result, &operation)
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          operation.call
          result << true
        rescue StandardError => error
          result << error
        end
      end
    end
end
