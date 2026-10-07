require "test_helper"

class WebPush::PoolTest < ActiveSupport::TestCase
  setup do
    stub_web_push_dns_resolution
    @pool = Rails.configuration.x.web_push_pool
    @payload = { title: "Designers", body: "Hello", path: Rails.application.routes.url_helpers.room_path(rooms(:designers)) }
  end

  test "every notification carries its subscriber's unread room count as the badge" do
    memberships(:jason_pets).update! unread_at: Time.current
    memberships(:kevin_hq).update! unread_at: Time.current
    memberships(:kevin_david_and_kevin).update! unread_at: Time.current
    subscriptions = Push::Subscription.where(user: users(:david, :jason, :kevin))
    expected = subscriptions.to_h { |subscription| [ subscription.endpoint, subscription.user.memberships.unread.count ] }
    assert_equal [ 0, 1, 2 ], expected.values.sort

    badges = Concurrent::Hash.new
    WebPush.stubs(:payload_send).with { |options| badges[options[:endpoint]] = JSON.parse(options[:message]).dig("options", "data", "badge") }
    @pool.queue(@payload, subscriptions)
    wait_for_deliveries(3)

    assert_equal expected, badges
  end

  test "queueing counts unread rooms per batch, not per subscription" do
    WebPush.stubs(:payload_send)

    two = Push::Subscription.where(user: users(:david, :jason))
    four = Push::Subscription.where(user: users(:david, :jason, :jz, :kevin))
    assert_equal [ 2, 4 ], [ two.count, four.count ]

    queries_for_two = count_queries { @pool.queue(@payload, two) }
    queries_for_four = count_queries { @pool.queue(@payload, four) }
    wait_for_deliveries(6)

    assert_equal queries_for_two, queries_for_four
  end

  private
    def wait_for_deliveries(count)
      Timeout.timeout(2) { sleep 0.01 while @pool.delivery_pool.completed_task_count < count }
    end

    def count_queries(&block)
      count = 0
      counter = ->(*, payload) { count += 1 unless payload[:name] == "SCHEMA" || payload[:cached] }
      ActiveRecord::Base.uncached do
        ActiveSupport::Notifications.subscribed(counter, "sql.active_record", &block)
      end
      count
    end
end
