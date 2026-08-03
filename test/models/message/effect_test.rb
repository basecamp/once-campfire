require "test_helper"

class Message::EffectTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @room = rooms(:watercooler)
    @creator = users(:david)
    @room.memberships.find_each(&:present)
    clear_enqueued_jobs
  end

  test "message client id validation counts bytes" do
    message = build_message
    boundary_id = "\u00E9" * (ContentLimits::CLIENT_MESSAGE_ID_BYTES / 2)
    effect = message.message_effects.build(
      effect: "broadcast_update", deduplication_key: SecureRandom.hex(8),
      room_id: message.room_id, message_client_id: boundary_id
    )
    assert_predicate effect, :valid?

    effect.message_client_id = "#{boundary_id}a"
    assert_not effect.valid?
    assert_includes effect.errors[:message_client_id],
      "is too long (maximum is #{ContentLimits::CLIENT_MESSAGE_ID_BYTES} bytes)"
  end

  test "enqueue failure backs final delivery off and retries after expiry" do
    MessageEffectJob.stubs(:perform_later).raises(Redis::CannotConnectError)
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(status: 200)

    message = build_message(body: "<div>Hey #{mention_attachment_for(:bender)}</div>")
    delivery = message.message_effects.find_by!(effect: "bot_webhook")

    assert_nil delivery.lease_token
    assert_nil delivery.completed_at
    assert_equal "Redis::CannotConnectError", delivery.last_error_class
    assert_equal 0, delivery.attempts
    assert_in_delta Time.current + ReliableWork::BASE_RETRY_DELAY, delivery.next_attempt_at, 1.second

    MessageEffectJob.unstub(:perform_later)
    assert_no_enqueued_jobs only: MessageEffectJob do
      assert_equal 0, message.dispatch_pending_effects
    end
    travel_to delivery.next_attempt_at + 1.second do
      assert_enqueued_jobs 1, only: MessageEffectJob do
        message.dispatch_pending_effects
      end
      perform_enqueued_jobs only: MessageEffectJob
    end

    assert delivery.reload.completed_at?
  end

  test "a stale worker cannot complete or release a replacement lease" do
    message = build_message
    effect = create_effect(message, "broadcast_update")
    stale_token = effect.acquire_lease
    assert effect.claim_for_processing!(stale_token)
    effect.update_columns(
      enqueued_at: ReliableWork::LEASE_DURATION.ago - 1.second,
      started_at: Time.current
    )
    assert_nil effect.reload.acquire_lease
    effect.update_columns(started_at: ReliableWork::LEASE_DURATION.ago - 1.second)

    current_token = effect.reload.acquire_lease
    assert_not_equal stale_token, current_token
    assert_not effect.complete!(stale_token)
    assert_not effect.release_for_retry!(stale_token, RuntimeError.new("stale"))
    assert_equal current_token, effect.reload.lease_token

    Message.any_instance.expects(:broadcast_update).once
    assert effect.reload.perform!(current_token)
    assert effect.reload.completed_at?
  end

  test "an unstarted queued job keeps its token when it is dispatched again" do
    effect = create_effect(build_message, "broadcast_update")
    token = effect.acquire_lease
    effect.update_columns(
      enqueued_at: ReliableWork::LEASE_DURATION.ago - 1.second, started_at: nil
    )
    MessageEffectJob.expects(:perform_later).with(effect.id, token).returns(true)

    assert effect.dispatch

    assert_equal token, effect.reload.lease_token
    assert_nil effect.started_at
    assert effect.claim_for_processing!(token)
    assert effect.complete!(token)
  end

  test "a failed queued-job redispatch does not invalidate the accepted token" do
    effect = create_effect(build_message, "broadcast_update")
    token = effect.acquire_lease
    effect.update_columns(
      enqueued_at: ReliableWork::LEASE_DURATION.ago - 1.second, started_at: nil
    )
    MessageEffectJob.expects(:perform_later).with(effect.id, token)
      .raises(Redis::CannotConnectError, "queue unavailable")

    assert_raises(Redis::CannotConnectError) { effect.dispatch }

    assert_equal token, effect.reload.lease_token
    assert_nil effect.started_at
    assert effect.claim_for_processing!(token)
  end

  test "failures back off exponentially and become visible dead letters" do
    effect = create_effect(build_message, "broadcast_update")
    Message.any_instance.stubs(:broadcast_update).raises(IOError, "broadcast unavailable")

    ReliableWork::MAX_ATTEMPTS.times do |index|
      effect.update_columns(next_attempt_at: nil) if index.positive?
      token = effect.reload.acquire_lease
      before = Time.current
      assert_raises(IOError) { effect.reload.perform!(token) }
      effect.reload

      assert_equal index + 1, effect.attempts
      assert_equal "IOError", effect.last_error_class
      assert_equal "broadcast unavailable", effect.last_error_message
      if index == ReliableWork::MAX_ATTEMPTS - 1
        assert effect.failed_at?
        assert_nil effect.next_attempt_at
      else
        expected = [
          ReliableWork::BASE_RETRY_DELAY * (2**index), ReliableWork::MAX_RETRY_DELAY
        ].min
        assert_in_delta before + expected, effect.next_attempt_at, 1.second
      end
    end

    assert_not Message::Effect.pending.exists?(effect.id)
    assert Message::Effect.dead_lettered.exists?(effect.id)

    Message.any_instance.unstub(:broadcast_update)
    MessageEffectJob.stubs(:perform_later).returns(true)
    assert effect.retry_dead_letter!
    assert_equal 0, effect.reload.attempts
    assert_nil effect.failed_at
    assert effect.lease_token?
  ensure
    Message.any_instance.unstub(:broadcast_update)
  end

  test "the Active Job entry point swallows a failure after durable retry is scheduled" do
    effect = create_effect(build_message, "broadcast_update")
    token = effect.acquire_lease
    Message.any_instance.stubs(:broadcast_update).raises(IOError, "broadcast unavailable")

    assert_not MessageEffectJob.perform_now(effect.id, token)

    assert_equal "IOError", effect.reload.last_error_class
    assert effect.next_attempt_at?
    assert_nil effect.lease_token
  ensure
    Message.any_instance.unstub(:broadcast_update)
  end

  test "dispatcher chooses due work in deterministic order" do
    message = build_message
    oldest = create_effect(message, "broadcast_update", key: "oldest")
    retrying = create_effect(message, "broadcast_update", key: "retrying")
    newest = create_effect(message, "broadcast_update", key: "newest")
    oldest.update_columns(created_at: 3.minutes.ago)
    retrying.update_columns(created_at: 2.minutes.ago, next_attempt_at: 2.5.minutes.ago)
    newest.update_columns(created_at: 1.minute.ago)
    dispatched = []
    MessageEffectJob.stubs(:perform_later).with { |id, _token| dispatched << id }.returns(true)

    Message::Effect.dispatch_pending(
      Message::Effect.pending.where(id: [ oldest.id, retrying.id, newest.id ]), limit: 2
    )

    assert_equal [ oldest.id, retrying.id ], dispatched
    assert_nil newest.reload.lease_token
  end

  test "bot webhook completion means the HTTP request returned and carries a persisted delivery id" do
    message = build_message(body: "<div>Hey #{mention_attachment_for(:bender)}</div>")
    effect = message.message_effects.find_by!(effect: "bot_webhook")
    request = WebMock.stub_request(:post, webhooks(:bender).url)
      .with(headers: { Webhook::IDEMPOTENCY_HEADER => effect.delivery_id }).to_return(status: 200)

    assert effect.perform!(effect.lease_token)

    assert_requested request, times: 1
    assert effect.reload.completed_at?
  end

  test "bot webhook retries reuse the same delivery id until a successful response" do
    message = build_message(body: "<div>Hey #{mention_attachment_for(:bender)}</div>")
    effect = message.message_effects.find_by!(effect: "bot_webhook")
    request = WebMock.stub_request(:post, webhooks(:bender).url)
      .with(headers: { Webhook::IDEMPOTENCY_HEADER => effect.delivery_id })
      .to_return({ status: 503 }, { status: 204 })

    assert_raises(Webhook::DeliveryError) { effect.perform!(effect.lease_token) }
    assert_nil effect.reload.completed_at
    assert effect.next_attempt_at?

    effect.update_columns(next_attempt_at: nil)
    assert effect.reload.perform_safely
    assert effect.reload.completed_at?
    assert_requested request, times: 2
  end

  test "webhook fanout remains idempotent when completion is interrupted" do
    message = build_message(body: "<div>Hey #{mention_attachment_for(:bender)}</div>")
    fanout = message.message_effects.find_by!(effect: "webhook_fanout")
    reset_effect fanout
    fanout.stubs(:complete!).raises("process stopped before completion")

    token = fanout.acquire_lease
    assert_raises(RuntimeError) { fanout.perform!(token) }
    assert_equal 1, message.message_effects.where(
      effect: "bot_webhook", recipient_id: users(:bender).id
    ).count

    fanout.unstub(:complete!)
    fanout.update_columns(next_attempt_at: nil)
    assert fanout.reload.perform_safely
    assert_equal 1, message.message_effects.where(
      effect: "bot_webhook", recipient_id: users(:bender).id
    ).count
  end

  test "bot reply remains idempotent when effect completion is interrupted" do
    message = build_message(body: "<div>Hey #{mention_attachment_for(:bender)}</div>")
    effect = message.message_effects.find_by!(effect: "bot_webhook")
    WebMock.stub_request(:post, webhooks(:bender).url).to_return(
      status: 200, body: "Exactly once", headers: { "Content-Type" => "text/plain" }
    )
    effect.stubs(:complete!).raises("process stopped after reply commit")

    assert_raises(RuntimeError) { effect.perform!(effect.lease_token) }
    reply_id = "webhook-reply-#{effect.delivery_id}"
    assert_equal 1, @room.messages.where(creator: users(:bender), client_message_id: reply_id).count

    effect.unstub(:complete!)
    effect.update_columns(next_attempt_at: nil)
    assert effect.reload.perform_safely

    replies = @room.messages.where(creator: users(:bender), client_message_id: reply_id)
    assert_equal 1, replies.count
    assert_equal 1, replies.sole.message_effects.where(effect: "broadcast_create").count
  end

  test "bot webhook is canceled when room membership was revoked" do
    message = build_message(body: "<div>Hey #{mention_attachment_for(:bender)}</div>")
    effect = message.message_effects.find_by!(effect: "bot_webhook")
    Membership.find_by!(room: @room, user: users(:bender)).destroy!
    WebMock.stub_request(:post, webhooks(:bender).url).to_raise("must not deliver")

    assert effect.perform!(effect.lease_token)

    assert effect.reload.canceled_at?
    assert_nil effect.completed_at
    assert_not_requested :post, webhooks(:bender).url
  end

  test "bot webhook is canceled when its endpoint generation rotates" do
    message = build_message(body: "<div>Hey #{mention_attachment_for(:bender)}</div>")
    effect = message.message_effects.find_by!(effect: "bot_webhook")
    original_generation = effect.webhook_generation
    webhooks(:bender).update!(url: "https://rotated.example.com/hook")

    assert_not_equal original_generation, webhooks(:bender).delivery_generation
    assert effect.perform!(effect.lease_token)
    assert effect.reload.canceled_at?
    assert_not_requested :post, webhooks(:bender).url
  end

  test "bot webhook is canceled when its endpoint is removed" do
    message = build_message(body: "<div>Hey #{mention_attachment_for(:bender)}</div>")
    effect = message.message_effects.find_by!(effect: "bot_webhook")
    removed_url = webhooks(:bender).url
    webhooks(:bender).destroy!

    assert effect.perform!(effect.lease_token)
    assert effect.reload.canceled_at?
    assert_not_requested :post, removed_url
  end

  test "retrying an older membership reconciliation does not regress the unread marker" do
    membership = memberships(:jason_watercooler)
    membership.update_columns(
      connected_at: nil, presence_tokens: {}, unread_at: nil, created_at: 3.minutes.ago
    )
    older = build_message(created_at: 2.minutes.ago)
    newer = build_message(created_at: 1.minute.ago)
    membership.update_columns(connected_at: nil, presence_tokens: {}, unread_at: nil)

    perform_effect newer.message_effects.find_by!(effect: "presence_reconcile", recipient_id: membership.id)
    perform_effect older.message_effects.find_by!(effect: "presence_reconcile", recipient_id: membership.id)

    assert_equal newer.created_at, membership.reload.unread_at
  end

  test "room receive retry after a read does not restore unread or duplicate push" do
    membership = memberships(:jason_watercooler)
    membership.update_columns(connected_at: nil, presence_tokens: {}, unread_at: nil)
    message = build_unperformed_message(client_message_id: "receive-retry-read")
    receive = fail_room_receive_after_recipient_work(message)
    push = message.message_effects.find_by!(
      effect: "push_delivery", recipient_id: push_subscriptions(:jason_chrome).id
    )
    Room::MessagePusher.any_instance.expects(:push_to).with(push.recipient_id).once
    perform_effect push

    membership.read
    clear_enqueued_jobs

    assert_no_difference -> { message.message_effects.where(effect: "push_delivery").count } do
      assert_no_enqueued_jobs only: MessageEffectJob do
        retry_effect receive
      end
    end
    assert_nil membership.reload.unread_at
    assert_equal 1, message.message_effects.where(effect: "push_delivery").count
  end

  test "room receive retry after a later presence disconnects does not restore unread or duplicate push" do
    membership = memberships(:jason_watercooler)
    membership.update_columns(connected_at: nil, presence_tokens: {}, unread_at: nil)
    message = build_unperformed_message(client_message_id: "receive-retry-presence")
    receive = fail_room_receive_after_recipient_work(message)
    push = message.message_effects.find_by!(
      effect: "push_delivery", recipient_id: push_subscriptions(:jason_chrome).id
    )
    Room::MessagePusher.any_instance.expects(:push_to).with(push.recipient_id).once
    perform_effect push

    presence = membership.present
    assert membership.absent(presence)
    clear_enqueued_jobs

    assert_no_difference -> { message.message_effects.where(effect: "push_delivery").count } do
      assert_no_enqueued_jobs only: MessageEffectJob do
        retry_effect receive
      end
    end
    assert_nil membership.reload.unread_at
    assert_not membership.connected?
    assert_equal 1, message.message_effects.where(effect: "push_delivery").count
  end

  test "room receive excludes memberships created after the message" do
    room = Rooms::Closed.create!(name: "Recipient snapshot", creator: @creator)
    room.memberships.create!(user: @creator, involvement: :nothing)
    message = build_unperformed_message(
      room:, client_message_id: "recipient-created-later"
    )
    membership = travel(1.second) do
      room.memberships.create!(user: users(:kevin), involvement: :everything)
    end
    receive = message.message_effects.find_by!(effect: "room_receive")

    assert receive.perform_safely

    assert receive.reload.completed_at?
    assert_not message.message_effects.exists?(
      effect: "presence_reconcile", recipient_id: membership.id
    )
    assert_nil membership.reload.unread_at
  end

  test "room receive journals and dispatches recipients in bounded deferred batches" do
    room = Rooms::Closed.create!(name: "Large recipient fanout", creator: @creator)
    room.memberships.create!(user: @creator, involvement: :nothing)
    now = Time.current
    user_ids = User.insert_all!(
      (Message::Effect::RECIPIENT_FANOUT_BATCH_SIZE + 1).times.map do |index|
        {
          name: "Fanout recipient #{index}", role: User.roles.fetch("member"),
          status: User.statuses.fetch("active"), created_at: now, updated_at: now
        }
      end,
      returning: %w[ id ]
    ).rows.flatten
    Membership.insert_all!(user_ids.map do |user_id|
      {
        room_id: room.id, user_id:, involvement: "nothing",
        created_at: now, updated_at: now
      }
    end)
    message = travel(1.second) do
      build_unperformed_message(room:, client_message_id: "bounded-recipient-fanout")
    end
    receive = message.message_effects.find_by!(effect: "room_receive")
    clear_enqueued_jobs

    assert receive.perform_safely

    recipient_effects = message.message_effects.where(effect: "presence_reconcile")
    assert_equal Message::Effect::RECIPIENT_FANOUT_BATCH_SIZE, recipient_effects.count
    assert_nil receive.reload.completed_at
    assert receive.lease_token?
    assert recipient_effects.where.not(started_at: nil).none?

    assert receive.perform!(receive.lease_token)

    assert_equal Message::Effect::RECIPIENT_FANOUT_BATCH_SIZE + 1, recipient_effects.count
    assert receive.reload.completed_at?
    assert recipient_effects.where.not(started_at: nil).none?
  end

  test "terminal effect pruning is bounded and preserves recent work and dead letters" do
    message = build_message
    oldest = create_effect(message, "broadcast_update", key: "oldest-terminal")
    old_canceled = create_effect(message, "broadcast_update", key: "old-canceled")
    recent = create_effect(message, "broadcast_update", key: "recent-terminal")
    dead_letter = create_effect(message, "broadcast_update", key: "dead-letter")
    oldest.update_columns(completed_at: 3.days.ago)
    old_canceled.update_columns(canceled_at: 2.days.ago)
    recent.update_columns(completed_at: 1.hour.ago)
    dead_letter.update_columns(failed_at: 3.days.ago)

    assert_equal 1, Message::Effect.prune_terminal!(before: 1.day.ago, limit: 1)
    assert_not Message::Effect.exists?(oldest.id)
    assert Message::Effect.exists?(old_canceled.id)

    assert_equal 1, Message::Effect.prune_terminal!(before: 1.day.ago, limit: 10)
    assert_not Message::Effect.exists?(old_canceled.id)
    assert Message::Effect.exists?(recent.id)
    assert Message::Effect.exists?(dead_letter.id)
  end

  test "fresh presence refresh cancels delayed unread and push reconciliation" do
    membership = memberships(:jason_watercooler)
    membership.update_columns(connected_at: nil, presence_tokens: {}, unread_at: nil)
    presence = membership.present
    message = build_message(client_message_id: "presence-refresh")
    effect = message.message_effects.find_by!(effect: "presence_reconcile", recipient_id: membership.id)

    travel_to effect.next_attempt_at - 10.seconds do
      assert membership.refresh_presence(presence)
    end
    travel_to effect.next_attempt_at + 1.second do
      assert effect.reload.perform_safely
    end

    assert effect.reload.canceled_at?
    assert_nil membership.reload.unread_at
    assert_not message.message_effects.where(effect: "push_delivery")
      .where(recipient_id: membership.user.push_subscriptions.select(:id)).exists?
  end

  test "expired presence reconciles unread state and one push per current subscription" do
    membership = memberships(:jason_watercooler)
    membership.update_columns(connected_at: nil, presence_tokens: {}, unread_at: nil)
    membership.present
    message = build_message(client_message_id: "presence-expired")
    effect = message.message_effects.find_by!(effect: "presence_reconcile", recipient_id: membership.id)

    travel_to effect.next_attempt_at + 1.second do
      assert effect.reload.perform_safely
    end

    subscription_ids = membership.user.push_subscriptions.with_current_session.ids
    assert_equal message.created_at, membership.reload.unread_at
    assert_equal subscription_ids.sort, message.message_effects
      .where(effect: "push_delivery", recipient_id: subscription_ids).pluck(:recipient_id).sort
    assert effect.reload.completed_at?
  end

  test "a later read generation cannot be regressed after it disconnects" do
    membership = memberships(:jason_watercooler)
    membership.update_columns(connected_at: nil, presence_tokens: {}, unread_at: nil)
    original_presence = membership.present
    message = build_message(client_message_id: "presence-read-generation")
    effect = message.message_effects.find_by!(effect: "presence_reconcile", recipient_id: membership.id)

    later_presence = membership.present(replacing: original_presence)
    assert membership.absent(later_presence)
    travel_to effect.next_attempt_at + 1.second do
      assert effect.reload.perform_safely
    end

    assert effect.reload.canceled_at?
    assert_nil membership.reload.unread_at
    assert_not message.message_effects.where(effect: "push_delivery")
      .where(recipient_id: membership.user.push_subscriptions.select(:id)).exists?
  end

  test "an explicit read after disconnect cancels reconciliation from an older generation" do
    membership = memberships(:jason_watercooler)
    membership.update_columns(connected_at: nil, presence_tokens: {}, unread_at: nil)
    presence = membership.present
    message = build_message(client_message_id: "presence-explicit-read")
    effect = message.message_effects.find_by!(effect: "presence_reconcile", recipient_id: membership.id)

    assert membership.absent(presence)
    membership.read
    travel_to effect.next_attempt_at + 1.second do
      assert effect.reload.perform_safely
    end

    assert effect.reload.canceled_at?
    assert_nil membership.reload.unread_at
    assert_not message.message_effects.where(effect: "push_delivery")
      .where(recipient_id: membership.user.push_subscriptions.select(:id)).exists?
  end

  test "webhook delivery holds membership revocation behind the delivery fence" do
    message = build_message(body: "<div>Hey #{mention_attachment_for(:bender)}</div>")
    effect = message.message_effects.find_by!(effect: "bot_webhook")
    membership = Membership.find_by!(room: @room, user: users(:bender))
    entered = Queue.new
    release = Queue.new
    Webhook.any_instance.stubs(:post).with do |*|
      entered << ActiveRecord::Base.connection.transaction_open?
      release.pop
      true
    end.returns(Net::HTTPNoContent.new("1.1", "204", "No Content"))

    delivery = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { effect.perform!(effect.lease_token) }
    end
    assert_not entered.pop
    revocation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { Membership.find(membership.id).destroy! }
    end

    sleep 0.05
    assert_predicate revocation, :alive?
    release << true
    assert delivery.value
    assert revocation.value
    assert_not Membership.exists?(membership.id)
  ensure
    release << true if delivery&.alive?
    delivery&.join(2)
    revocation&.join(2)
  end

  test "membership revocation committing first cancels a fenced webhook delivery" do
    message = build_message(body: "<div>Hey #{mention_attachment_for(:bender)}</div>")
    effect = message.message_effects.find_by!(effect: "bot_webhook")
    bot = users(:bender)
    membership = Membership.find_by!(room: @room, user: bot)
    mutation_ready = Queue.new
    release_mutation = Queue.new
    mutation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        User::MutationFence.with(bot.id) do
          Membership.transaction do
            Membership.find(membership.id).destroy!
            mutation_ready << true
            release_mutation.pop
          end
        end
      end
    end
    mutation_ready.pop
    Webhook.any_instance.expects(:post).never
    delivery = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { effect.perform!(effect.lease_token) }
    end

    assert_predicate delivery, :alive?
    release_mutation << true
    mutation.value
    assert delivery.value
    assert effect.reload.canceled_at?
  ensure
    release_mutation << true if mutation&.alive?
    mutation&.join(2)
    delivery&.join(2)
  end

  test "URL rotation waits for in-flight delivery and invalidates later attempts" do
    message = build_message(body: "<div>Hey #{mention_attachment_for(:bender)}</div>")
    effect = message.message_effects.find_by!(effect: "bot_webhook")
    entered = Queue.new
    release = Queue.new
    Webhook.any_instance.stubs(:post).with do |*|
      entered << true
      release.pop
      true
    end.returns(Net::HTTPNoContent.new("1.1", "204", "No Content"))

    delivery = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection { effect.perform!(effect.lease_token) }
    end
    entered.pop
    rotation = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        Webhook.find(effect.webhook_id).update!(url: "https://rotated.example.com/hook")
      end
    end

    sleep 0.05
    assert_predicate rotation, :alive?
    release << true
    assert delivery.value
    assert rotation.value

    reset_effect effect
    Webhook.any_instance.expects(:post).never
    assert effect.reload.perform_safely
    assert effect.reload.canceled_at?
  ensure
    release << true if delivery&.alive?
    delivery&.join(2)
    rotation&.join(2)
  end

  test "failed update broadcast remains durable and reconciles the current message" do
    message = build_message
    Message.any_instance.stubs(:broadcast_update).raises("cable unavailable")

    assert_nothing_raised { message.update_with_broadcast!({ body: "Current body" }, actor: @creator) }
    effect = message.message_effects.find_by!(effect: "broadcast_update")
    assert_nil effect.completed_at
    assert_equal "cable unavailable", effect.last_error_message

    Message.any_instance.unstub(:broadcast_update)
    effect.update_columns(next_attempt_at: nil)
    assert effect.reload.perform_safely
    assert effect.reload.completed_at?
    assert_equal "Current body", message.reload.plain_text_body
  end

  test "failed destroy broadcast survives the deleted message" do
    message = build_message
    Message.stubs(:broadcast_destroy).raises("cable unavailable")

    message.destroy!
    effect = Message::Effect.find_by!(
      message_id: message.id, effect: "broadcast_destroy"
    )
    assert_not Message.exists?(message.id)
    assert_nil effect.message
    assert_nil effect.completed_at

    Message.unstub(:broadcast_destroy)
    effect.update_columns(next_attempt_at: nil)
    assert effect.reload.perform_safely
    assert effect.reload.completed_at?
  end

  private
    def build_message(body: "Durable effects", client_message_id: SecureRandom.hex(8), **attributes)
      @room.messages.create!(creator: @creator, body:, client_message_id:, **attributes).tap do
        clear_enqueued_jobs
      end
    end

    def build_unperformed_message(body: "Durable effects", client_message_id:, room: @room, **attributes)
      message = room.messages.build(creator: @creator, body:, client_message_id:, **attributes)
      message.stubs(:perform_reliable_effects)
      message.save!
      message
    ensure
      message&.unstub(:perform_reliable_effects)
      clear_enqueued_jobs
    end

    def fail_room_receive_after_recipient_work(message)
      effect = message.message_effects.find_by!(effect: "room_receive")
      effect.stubs(:complete!).raises("process stopped after unread work")

      token = effect.acquire_lease
      assert_raises(RuntimeError) { effect.perform!(token) }
      perform_effect message.message_effects.find_by!(
        effect: "presence_reconcile", recipient_id: memberships(:jason_watercooler).id
      )
      assert_equal message.created_at, memberships(:jason_watercooler).reload.unread_at
      effect
    ensure
      effect&.unstub(:complete!)
    end

    def create_effect(message, effect, key: SecureRandom.hex(8), recipient_id: nil)
      message.message_effects.create!(
        effect:, deduplication_key: "#{effect}:#{key}", recipient_id:,
        room_id: message.room_id, message_client_id: message.client_message_id
      )
    end

    def reset_effect(effect)
      effect.update_columns(
        completed_at: nil, canceled_at: nil, failed_at: nil, lease_token: nil, enqueued_at: nil,
        started_at: nil, next_attempt_at: nil, attempts: 0
      )
    end

    def perform_effect(effect)
      reset_effect effect
      assert effect.reload.perform_safely
    end

    def retry_effect(effect)
      effect.update_columns(next_attempt_at: nil)
      assert effect.reload.perform_safely
    end
end
