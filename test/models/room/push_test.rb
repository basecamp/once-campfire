require "test_helper"

class Room::PushTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  self.use_transactional_tests = false

  setup { replace_web_push_pool }
  teardown { restore_web_push_pool }

  test "deliver new message to other room users with push subscriptions" do
    task_count = Push::Subscription.count - users(:david).push_subscriptions.count
    perform_enqueued_jobs only: [ MessageEffectJob, Room::PushMessageJob ] do
      WebPush.expects(:payload_send).times(task_count)
      rooms(:hq).messages.create! body: "This is from earth", client_message_id: "earth", creator: users(:david)
    end
  end

  test "notifies subscribed users" do
    perform_enqueued_jobs only: [ MessageEffectJob, Room::PushMessageJob ] do
      WebPush.expects(:payload_send).times(2)
      rooms(:designers).messages.create! body: "This is from earth", client_message_id: "earth", creator: users(:david)
    end

    perform_enqueued_jobs only: [ MessageEffectJob, Room::PushMessageJob ] do
      WebPush.expects(:payload_send).times(3)
      rooms(:designers).messages.create! body: "Hey #{mention_attachment_for(:kevin)}", client_message_id: "earth-mention", creator: users(:david)
    end
  end

  test "does not notify for connected rooms" do
    memberships(:kevin_designers).present

    perform_enqueued_jobs only: [ MessageEffectJob, Room::PushMessageJob ] do
      WebPush.expects(:payload_send).times(2)
      rooms(:designers).messages.create! body: "Hey @kevin", client_message_id: "earth", creator: users(:david)
    end
  end

  test "does not notify for invisible rooms" do
    memberships(:kevin_designers).update! involvement: "invisible"

    perform_enqueued_jobs only: [ MessageEffectJob, Room::PushMessageJob ] do
      WebPush.expects(:payload_send).times(2)
      rooms(:designers).messages.create! body: "Hey @kevin", client_message_id: "earth", creator: users(:david)
    end
  end

  test "destroys invalid subscriptions" do
    memberships(:kevin_designers).update! involvement: "invisible"

    assert_difference -> { Push::Subscription.count }, -2 do
      perform_enqueued_jobs only: [ MessageEffectJob, Room::PushMessageJob ] do
        WebPush.expects(:payload_send).times(2).raises(WebPush::ExpiredSubscription.new(Struct.new(:body).new, "example.com"))
        rooms(:designers).messages.create! body: "Hey @kevin", client_message_id: "earth", creator: users(:david)
      end
    end
  end

  test "retries transient TLS failures without deleting the subscription" do
    subscription = push_subscriptions(:jz_chrome)
    pool = replace_web_push_pool(retry_delays: [ 0, 0 ], sleeper: ->(_delay) { })
    attempts = 0
    WebPush.stubs(:payload_send).with do |*|
      attempts += 1
      raise OpenSSL::SSL::SSLError, "temporary TLS failure" if attempts < 3
      true
    end

    pool.queue(
      { title: "Private", body: "retry", path: "/" },
      Push::Subscription.where(id: subscription.id),
      room: rooms(:designers), message: messages(:second)
    )

    assert_equal 3, attempts
    assert Push::Subscription.exists?(subscription.id)
  end

  test "push effects complete only after accepted delivery work returns" do
    memberships(:jason_designers).update!(involvement: :nothing)
    memberships(:kevin_designers).update!(involvement: :invisible)
    message = messages(:second)
    effect = message.message_effects.create!(
      effect: "push_delivery", deduplication_key: "push-waits",
      recipient_id: push_subscriptions(:jz_chrome).id,
      room_id: message.room_id, message_client_id: message.client_message_id
    )
    clear_enqueued_jobs
    started = Queue.new
    release = Queue.new
    WebPush.stubs(:payload_send).with do |*|
      started << true
      release.pop
      true
    end

    worker = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        effect.reload.perform!(effect.lease_token)
      end
    end
    started.pop

    assert_predicate worker, :alive?
    assert_nil effect.reload.completed_at
    release << true
    worker.value
    assert effect.reload.completed_at?
  ensure
    release << true if worker&.alive?
    worker&.join(2)
  end

  test "does not deliver a queued notification after session revocation" do
    subscription = push_subscriptions(:jz_chrome)
    pool = replace_web_push_pool(max_threads: 1)
    delivery_pool = pool.delivery_pool
    started = Queue.new
    release = Queue.new
    delivery_pool.post { started << true; release.pop }
    started.pop

    WebPush.expects(:payload_send).never
    delivery = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        pool.queue(
          { title: "Private", body: "revoked", path: "/rooms/1" },
          Push::Subscription.where(id: subscription.id),
          room: rooms(:designers), message: messages(:second)
        )
      end
    end
    wait_until { delivery_pool.queue_length == 1 }
    subscription.session.destroy!
    release << true

    delivery.value
  ensure
    release << true if delivery&.alive?
    delivery&.join(2)
  end

  test "does not deliver after the recipient disables notifications" do
    subscription = push_subscriptions(:jz_chrome)
    pool = replace_web_push_pool(max_threads: 1)
    delivery_pool = pool.delivery_pool
    started = Queue.new
    release = Queue.new
    delivery_pool.post { started << true; release.pop }
    started.pop

    WebPush.expects(:payload_send).never
    delivery = Thread.new do
      ActiveRecord::Base.connection_pool.with_connection do
        pool.queue(
          { title: "Private", body: "preference changed", path: "/rooms/1" },
          Push::Subscription.where(id: subscription.id),
          room: rooms(:designers), message: messages(:second)
        )
      end
    end
    wait_until { delivery_pool.queue_length == 1 }
    memberships(:jz_designers).update!(involvement: :nothing)
    release << true

    delivery.value
  ensure
    release << true if delivery&.alive?
    delivery&.join(2)
  end

  test "queued push payloads contain no room, sender, or message content" do
    message = rooms(:designers).messages.create!(
      body: "private launch code", client_message_id: "generic-push", creator: users(:david)
    )

    payload = Room::MessagePusher.new(room: message.room, message:).send(:build_payload)

    assert_equal "New Campfire message", payload.fetch(:title)
    assert_equal "Open Campfire to view it.", payload.fetch(:body)
    assert_equal "/", payload.fetch(:path)
    assert_not_includes payload.to_json, "private launch code"
    assert_not_includes payload.to_json, message.room.name
    assert_not_includes payload.to_json, message.creator.name
  end

  test "encoded push payload uses the generic Campfire icon" do
    notification = WebPush::Notification.new(
      title: "New Campfire message", body: "Open Campfire to view it.", path: "/", badge: 0,
      endpoint: "https://push.example.test", p256dh_key: "key", auth_key: "auth"
    )

    payload = JSON.parse(notification.send(:encoded_message))

    assert_equal ActionController::Base.helpers.asset_path("campfire-icon.png"), payload.dig("options", "icon")
    assert_not_equal Rails.application.routes.url_helpers.account_logo_path, payload.dig("options", "icon")
  end

  private
    def replace_web_push_pool(**options)
      if @original_web_push_pool
        Rails.configuration.x.web_push_pool.shutdown
      else
        @original_web_push_pool = Rails.configuration.x.web_push_pool
      end
      Rails.configuration.x.web_push_pool = WebPush::Pool.new(
        invalid_subscription_handler: @original_web_push_pool.invalid_subscription_handler, **options
      )
    end

    def restore_web_push_pool
      return unless @original_web_push_pool

      Rails.configuration.x.web_push_pool.shutdown
      Rails.configuration.x.web_push_pool = @original_web_push_pool
      @original_web_push_pool = nil
    end

    def wait_until(timeout: 2)
      Timeout.timeout(timeout) do
        sleep 0.01 until yield
      end
    end
end
