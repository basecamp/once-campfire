ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"

require "rails/test_help"
require "mocha/minitest"
require "webmock/minitest"
require "turbo/broadcastable/test_helper"

# maintain_test_schema! may reload schema.rb after after_initialize; triggers are
# not dumped, so ensure they exist before fixtures insert messages.
Room::MessagesCount.ensure!

WebMock.enable!

module RoomMessagesCountFixtures
  # Fixture YAML still inserts messages before rooms via some load paths, so
  # INSERT triggers can update zero room rows. Reconcile once after load.
  def load_fixtures(config)
    fixtures = super
    Room::MessagesCount.backfill!
    fixtures
  end
end

class ActiveSupport::TestCase
  include ActiveJob::TestHelper
  prepend RoomMessagesCountFixtures

  parallelize(workers: :number_of_processors)

  # Prefer rooms before messages when the loader honors declaration order.
  fixtures :accounts, :users, :rooms, :memberships, :messages, "action_text/rich_texts",
           :boosts, :searches, :sessions, :webhooks, "push/subscriptions"

  include SessionTestHelper, MentionTestHelper, TurboTestHelper, DnsTestHelper

  setup do
    ActionCable.server.pubsub.clear

    Rails.configuration.tap do |config|
      config.x.web_push_pool.shutdown
      config.x.web_push_pool = WebPush::Pool.new \
        invalid_subscription_handler: config.x.web_push_pool.invalid_subscription_handler
    end

    WebMock.disable_net_connect!
  end

  teardown do
    WebMock.reset!
  end
end
