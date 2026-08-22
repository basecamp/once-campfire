require "test_helper"

class ReliableWorkDispatcherTest < ActiveSupport::TestCase
  setup do
    ReliableWork::Dispatcher.send(:reset_enqueue_circuit)
    BanCleanupIntent.delete_all
    Message::Effect.delete_all
    StagedUpload.stubs(:sweep_abandoned!)
    clear_enqueued_jobs
  end

  teardown do
    ReliableWork::Dispatcher.send(:reset_enqueue_circuit)
  end

  test "queue outages stop the scan and back repeated passes off until enqueue recovers" do
    first = create_intent(users(:david), 101)
    second = create_intent(users(:jason), 101)
    effect = create_effect

    RemoveBannedContentJob.expects(:perform_later)
      .with(first.id, anything).raises(Redis::CannotConnectError, "queue unavailable")
    MessageEffectJob.stubs(:perform_later).returns(true)

    assert_not ReliableWork::Dispatcher.dispatch_pending
    assert_equal "Redis::CannotConnectError", first.reload.last_error_class
    assert_in_delta Time.current + ReliableWork.enqueue_retry_delay(1), first.next_attempt_at, 1.second
    assert_nil second.reload.last_error_at
    assert_nil effect.reload.last_error_at
    assert_nil first.lease_token
    assert_nil second.lease_token
    assert_nil effect.lease_token

    updated_at = [ first.updated_at, second.updated_at, effect.updated_at ]
    3.times { assert_not ReliableWork::Dispatcher.dispatch_pending }
    assert_equal updated_at, [ first.reload.updated_at, second.reload.updated_at, effect.reload.updated_at ]

    RemoveBannedContentJob.expects(:perform_later)
      .with(second.id, anything).raises(Redis::CannotConnectError, "queue unavailable")
    travel_to first.next_attempt_at, with_usec: true do
      assert_not ReliableWork::Dispatcher.dispatch_pending
    end
    assert_nil effect.reload.lease_token
    assert_in_delta(
      first.next_attempt_at + ReliableWork.enqueue_retry_delay(2),
      second.reload.next_attempt_at,
      1.second
    )

    second_retry_at = second.next_attempt_at
    travel_to second_retry_at - 1.second do
      2.times { assert_not ReliableWork::Dispatcher.dispatch_pending }
    end

    RemoveBannedContentJob.unstub(:perform_later)
    MessageEffectJob.unstub(:perform_later)
    travel_to second_retry_at, with_usec: true do
      assert_enqueued_jobs 3 do
        assert ReliableWork::Dispatcher.dispatch_pending
      end
      assert first.reload.lease_token?
      assert second.reload.lease_token?
      assert effect.reload.lease_token?

      retry_after_success = create_intent(users(:kevin), 101)
      RemoveBannedContentJob.stubs(:perform_later).raises(
        Redis::CannotConnectError, "queue unavailable again"
      )
      assert_not ReliableWork::Dispatcher.dispatch_pending
      assert_in_delta(
        Time.current + ReliableWork.enqueue_retry_delay(1),
        retry_after_success.reload.next_attempt_at,
        1.second
      )
    end
  end

  test "an item serialization failure does not open the queue outage circuit" do
    bad = create_effect
    good = create_effect
    dispatch_order = sequence("serialized item then healthy item")
    MessageEffectJob.expects(:perform_later).with(bad.id, anything)
      .in_sequence(dispatch_order).raises(ActiveJob::SerializationError, "bad job arguments")
    MessageEffectJob.expects(:perform_later).with(good.id, anything)
      .in_sequence(dispatch_order).returns(true)

    assert ReliableWork::Dispatcher.dispatch_pending
    assert_equal "ActiveJob::SerializationError", bad.reload.last_error_class
    assert_nil bad.lease_token
    assert good.reload.lease_token?

    another = create_effect
    MessageEffectJob.expects(:perform_later).with(another.id, anything).returns(true)
    assert ReliableWork::Dispatcher.dispatch_pending
    assert another.reload.lease_token?
  end

  private
    def create_intent(user, generation)
      now = Time.current
      BanCleanupIntent.insert_all!([ { user_id: user.id, generation:, created_at: now, updated_at: now } ])
      BanCleanupIntent.find_by!(user:, generation:)
    end

    def create_effect
      message = messages(:first)
      Message::Effect.create!(
        message:, effect: "broadcast_update", deduplication_key: SecureRandom.uuid,
        room_id: message.room_id, message_client_id: message.client_message_id
      )
    end
end
