ENV["RAILS_ENV"] ||= "test"
require "fileutils"

operation_lock_root = File.join(
  File.realpath(Dir.home), ".campfire-operation-locks-test-#{Process.uid}"
)
FileUtils.mkdir_p operation_lock_root, mode: 0o700
File.chmod 0o700, operation_lock_root
ENV["CAMPFIRE_OPERATION_LOCK_ROOT"] ||= operation_lock_root

require_relative "../config/environment"

require "rails/test_help"
require "minitest/unit"
require "mocha/minitest"
require "webmock/minitest"
require "turbo/broadcastable/test_helper"

WebMock.enable!

default_web_push_pool = Rails.configuration.x.web_push_pool
default_web_push_pool.shutdown
Rails.configuration.x.web_push_pool = WebPush::Pool.new(
  invalid_subscription_handler: default_web_push_pool.invalid_subscription_handler,
  delivery_handler: ->(*) { true }
)

class ActiveSupport::TestCase
  include ActiveJob::TestHelper

  parallelize(workers: :number_of_processors)

  # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
  fixtures :all

  include SessionTestHelper, MentionTestHelper, TurboTestHelper, OidcTestHelper, ScimTestHelper, RawTlsServerTestHelper

  setup do
    Rails.cache.clear
    ActionCable.server.pubsub.clear
    WebMock.disable_net_connect!
  end

  teardown do
    reset_scim_configuration
    reset_oidc_configuration
    WebMock.reset!
  end
end
