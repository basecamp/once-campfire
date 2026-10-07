ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"

require "rails/test_help"
require "mocha/minitest"
require "webmock/minitest"
require "turbo/broadcastable/test_helper"

WebMock.enable!

class ActiveSupport::TestCase
  include ActiveJob::TestHelper

  parallelize(workers: :number_of_processors)

  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

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

  # fixtures :all inserts messages before rooms, so INSERT triggers cannot count
  # yet. Backfill once after load; ensure! covers schema.rb (triggers not dumped).
  def load_fixtures(config)
    fixtures = super
    Room::MessagesCount.ensure!
    Room::MessagesCount.backfill!
    fixtures
  end
end
