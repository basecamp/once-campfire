require "test_helper"

class AdministratorRosterConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @administrators = [ users(:david), users(:jason) ]
    @original_administrator_ids = User.where(role: :administrator).ids
    User.where(role: :administrator).where.not(id: @administrators.map(&:id)).update_all(role: :member)
    User.where(id: @administrators.map(&:id)).update_all(role: :administrator, status: :active)
  end

  teardown do
    User.where(role: :administrator).update_all(role: :member)
    User.where(id: @original_administrator_ids).update_all(role: :administrator, status: :active)
  end

  test "concurrent demotions cannot remove every active administrator" do
    barrier = Concurrent::CyclicBarrier.new(@administrators.size)
    results = Queue.new
    workers = @administrators.map do |administrator|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait
          User::MutationFence.with_administrator_roster do
            User::MutationFence.with(administrator.id) do
              administrator.update_role_by!({ role: "member" }, actor: administrator)
              results << :demoted
            end
          end
        rescue StandardError => error
          results << error
        end
      end
    end
    workers.each { assert _1.join(5), "administrator demotion deadlocked" }

    outcomes = @administrators.size.times.map { results.pop }
    assert_equal 1, outcomes.count(:demoted)
    assert_equal 1, outcomes.count { _1.is_a?(User::LastAdministratorError) }
    assert_equal 1, User.active.where(role: :administrator).count
  ensure
    workers&.each { _1.join(2) }
  end


  test "opposing administrator requests do not invert actor and roster fences" do
    barrier = Concurrent::CyclicBarrier.new(@administrators.size)
    results = Queue.new
    requests = [ @administrators, @administrators.reverse ]
    workers = requests.map do |actor, target|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier.wait
          User::MutationFence.with_administrator_roster do
            User::MutationFence.with(actor.id) do
              target.update_role_by!({ role: "member" }, actor:)
              results << :demoted
            end
          end
        rescue StandardError => error
          results << error
        end
      end
    end
    workers.each { assert _1.join(5), "opposing administrator requests deadlocked" }

    outcomes = @administrators.size.times.map { results.pop }
    assert_equal 1, outcomes.count(:demoted)
    assert_equal 1, outcomes.count { _1.is_a?(User::AuthorizationError) }
    assert_equal 1, User.active.where(role: :administrator).count
  ensure
    workers&.each { _1.join(2) }
  end
end
