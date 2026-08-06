require "test_helper"

class Oidc::ReadinessRedisIntegrationTest < ActiveSupport::TestCase
  test "production RedisCacheStore satisfies the readiness contract" do
    unless ENV["CAMPFIRE_REDIS_INTEGRATION"] == "true"
      skip "set CAMPFIRE_REDIS_INTEGRATION=true to exercise the production cache store"
    end

    store = ActiveSupport::Cache::RedisCacheStore.new(url: ENV.fetch("REDIS_URL"))

    assert Oidc::Readiness.ready?(store:)
  end
end
