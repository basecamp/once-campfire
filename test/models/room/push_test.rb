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

  private
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
