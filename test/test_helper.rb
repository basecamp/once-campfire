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
  # Fixture YAML loads alphabetically, so messages are inserted before rooms.
  # INSERT triggers then update zero room rows; reconcile once after load.
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

  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  include SessionTestHelper, MentionTestHelper, TurboTestHelper, DnsTestHelper

  setup do
    # DROP TRIGGER commits outside transactional fixtures; put triggers back each test.
    Room::MessagesCount.ensure!

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

