require "test_helper"

class Room::PushTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    stub_web_push_dns_resolution
  end

  test "deliver new message to other room users with push subscriptions" do
    task_count = Push::Subscription.count - users(:david).push_subscriptions.count
    perform_enqueued_jobs only: Room::PushMessageJob do
      WebPush.expects(:payload_send).times(task_count)
      rooms(:hq).messages.create! body: "This is from earth", client_message_id: "earth", creator: users(:david)
    end
    wait_for_web_push_delivery_pool_tasks(task_count)
  end

  test "notifies subscribed users" do
    perform_enqueued_jobs only: Room::PushMessageJob do
      WebPush.expects(:payload_send).times(2)
      rooms(:designers).messages.create! body: "This is from earth", client_message_id: "earth", creator: users(:david)
    end
    wait_for_web_push_delivery_pool_tasks(2)

    perform_enqueued_jobs only: Room::PushMessageJob do
      WebPush.expects(:payload_send).times(3)
      rooms(:designers).messages.create! body: "Hey #{mention_attachment_for(:kevin)}", client_message_id: "earth", creator: users(:david)
    end
    wait_for_web_push_delivery_pool_tasks(5)
  end

  test "does not notify for connected rooms" do
    memberships(:kevin_designers).connected

    perform_enqueued_jobs only: Room::PushMessageJob do
      WebPush.expects(:payload_send).times(2)
      rooms(:designers).messages.create! body: "Hey @kevin", client_message_id: "earth", creator: users(:david)
    end
    wait_for_web_push_delivery_pool_tasks(2)
  end

  test "does not notify for invisible rooms" do
    memberships(:kevin_designers).update! involvement: "invisible"

    perform_enqueued_jobs only: Room::PushMessageJob do
      WebPush.expects(:payload_send).times(2)
      rooms(:designers).messages.create! body: "Hey @kevin", client_message_id: "earth", creator: users(:david)
    end
    wait_for_web_push_delivery_pool_tasks(2)
  end

  test "destroys invalid subscriptions" do
    memberships(:kevin_designers).update! involvement: "invisible"

    assert_difference -> { Push::Subscription.count }, -2 do
      perform_enqueued_jobs only: Room::PushMessageJob do
        WebPush.expects(:payload_send).times(2).raises(WebPush::ExpiredSubscription.new(Struct.new(:body).new, "example.com"))
        rooms(:designers).messages.create! body: "Hey @kevin", client_message_id: "earth", creator: users(:david)
      end
      wait_for_web_push_delivery_pool_tasks(2)
      wait_for_invalidation_pool_tasks(2)
    end
  end

  test "does not notify banned users" do
    users(:kevin).ban

    assert_not_includes pushed_users { post_to_designers_mentioning_kevin }, users(:kevin)
  end

  test "notifies users again once they're unbanned" do
    users(:kevin).ban
    users(:kevin).unban

    assert_includes pushed_users { post_to_designers_mentioning_kevin }, users(:kevin)
  end

  test "does not notify banned users of direct messages" do
    users(:kevin).ban

    pushed = pushed_users do
      rooms(:david_and_kevin).messages.create! body: "Just between us", client_message_id: "earth", creator: users(:david)
    end
    assert_not_includes pushed, users(:kevin)
  end

  test "notifies active users mentioned" do
    assert_includes pushed_users { post_to_designers_mentioning_kevin }, users(:kevin)
  end

  test "a long message's notification still goes out, with the start of the message" do
    text = "All work and no play makes Jack a dull boy. " * 100

    { rooms(:designers) => "David: ", rooms(:david_and_kevin) => "" }.each do |room, prefix|
      notifications = sent_notifications { room.messages.create! body: text, client_message_id: "jack", creator: users(:david) }

      assert_not_empty notifications
      notifications.each do |notification|
        assert_nothing_raised { encrypt_for_a_browser(notification) }
        assert_equal "#{prefix}#{text.strip.truncate(200, omission: "…")}", JSON.parse(notification).dig("options", "body")
      end
    end
  end

  test "does not build notification payloads without recipients" do
    Push::Subscription.delete_all
    message = messages(:first)
    message.expects(:plain_text_body).never
    message.expects(:creator).never
    Rails.configuration.x.web_push_pool.expects(:queue).never

    Room::MessagePusher.new(room: message.room, message: message).push
  end

  private
    def post_to_designers_mentioning_kevin
      rooms(:designers).messages.create! body: "Hey #{mention_attachment_for(:kevin)}", client_message_id: "earth", creator: users(:david)
    end

    def pushed_users(&block)
      queued = []
      Rails.configuration.x.web_push_pool.stubs(:queue).with { |_payload, subscriptions| queued.concat subscriptions.to_a }
      perform_enqueued_jobs(only: Room::PushMessageJob, &block)
      queued.map(&:user).uniq
    end

    def sent_notifications(&block)
      notifications = Concurrent::Array.new
      WebPush.stubs(:payload_send).with { |message:, **| notifications << message }
      perform_enqueued_jobs(only: Room::PushMessageJob, &block)

      deliveries = Rails.configuration.x.web_push_pool.delivery_pool
      Timeout.timeout(2) { sleep 0.01 until deliveries.completed_task_count == deliveries.scheduled_task_count }
      notifications.to_a
    end

    # The same encryption a delivery goes through, for a subscription a browser made.
    def encrypt_for_a_browser(notification)
      browser_key = OpenSSL::PKey::EC.generate("prime256v1")
      WebPush::Encryption.encrypt notification,
        Base64.urlsafe_encode64(browser_key.public_key.to_bn.to_s(2)), Base64.urlsafe_encode64(Random.bytes(16))
    end

    def wait_for_web_push_delivery_pool_tasks(count)
      wait_for_pool_tasks(Rails.configuration.x.web_push_pool.delivery_pool, count)
    end

    def wait_for_invalidation_pool_tasks(count)
      wait_for_pool_tasks(Rails.configuration.x.web_push_pool.invalidation_pool, count)
    end

    def wait_for_pool_tasks(pool, count)
      start = Time.now
      timeout = 0.2
      while pool.completed_task_count < count
        raise "Timeout waiting for pool tasks to complete" if Time.now - start > timeout
        sleep timeout / 10.0
      end
    end
end
