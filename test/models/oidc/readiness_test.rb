require "test_helper"

class Oidc::ReadinessTest < ActiveSupport::TestCase
  class TrackingStore
    attr_reader :operations

    def initialize
      @store = ActiveSupport::Cache::MemoryStore.new
      @operations = []
    end

    %i[ write read increment delete ].each do |operation|
      define_method(operation) do |*arguments, **options|
        operations << operation
        @store.public_send(operation, *arguments, **options)
      end
    end
  end

  test "exercises write increment and delete semantics" do
    store = TrackingStore.new

    assert Oidc::Readiness.ready?(store:)
    assert_equal 1, store.operations.count(:write)
    assert_equal 2, store.operations.count(:increment)
    assert_equal 2, store.operations.count(:delete)
  end

  test "fails closed when deletion is not confirmed" do
    store = TrackingStore.new
    store.stubs(:delete).returns(false)

    assert_not Oidc::Readiness.ready?(store:)
  end
end
