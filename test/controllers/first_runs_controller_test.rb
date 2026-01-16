require "test_helper"

class FirstRunsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Account.destroy_all
    User.destroy_all
    Room.destroy_all
  end

  test "new is permitted when no other users exit" do
    get first_run_url
    assert_response :success
  end

  test "new is not permitted when account exist" do
    Account.create!(name: "Chat")

    get first_run_url
    assert_redirected_to root_url
  end

  test "create" do
    assert_difference -> { Room.count }, 1 do
      assert_difference -> { User.count }, 1 do
        post first_run_url, params: { account: { name: "37signals" }, user: { name: "New Person", email_address: "new@37signals.com", password: "secret123456" } }
      end
    end

    assert_redirected_to root_url

    assert parsed_cookies.signed[:session_token]
  end

  test "create is not vulnerable to race conditions" do
    num_attackers = 5
    url = first_run_url
    barrier = Concurrent::CyclicBarrier.new(num_attackers)

    num_attackers.times.map do |i|
      Thread.new do
        session = ActionDispatch::Integration::Session.new(Rails.application)
        barrier.wait  # All threads wait here, then fire simultaneously

        session.post url, params: {
          user: {
            name: "Attacker#{i}",
            email_address: "attacker#{i}@example.com",
            password: "password123"
          }
        }
      end
    end.each(&:join)

    assert_equal 1, Account.count, "Race condition allowed #{Account.count} accounts to be created!"
    assert_equal 1, User.where(role: :administrator).count, "Race condition allowed multiple admin users!"
  end
end
