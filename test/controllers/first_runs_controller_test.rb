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
        post first_run_url, params: {
          account: { name: "37signals" },
          user: { name: "New Person", email_address: " NEW@37SIGNALS.COM ", password: "secret123456" }
        }
      end
    end

    assert_redirected_to root_url

    assert parsed_cookies.signed[:session_token]
    assert_equal "new@37signals.com", User.sole.email_address
    assert_equal User.sole.email_address, User.sole.normalized_email_address
  end

  test "required OIDC mode rejects first run before mutation" do
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => "admin@example.com")

    assert_no_difference [ -> { Account.count }, -> { User.count }, -> { Room.count } ] do
      post first_run_url, params: {
        account: { name: "37signals" },
        user: { name: "Admin", email_address: "admin@example.com", password: "secret123456" }
      }
    end

    assert_response :service_unavailable
  end

  test "session creation failure rolls back setup so first run can be retried" do
    Session.stubs(:start!).raises(ActiveRecord::RecordInvalid.new(Session.new))
    params = {
      account: { name: "37signals" },
      user: { name: "New Person", email_address: "retry@37signals.com", password: "secret123456" }
    }

    assert_no_difference [ -> { Account.count }, -> { User.count }, -> { Room.count } ] do
      assert_raises(ActiveRecord::RecordInvalid) { post first_run_url, params: }
    end

    Session.unstub(:start!)
    post first_run_url, params: params

    assert_redirected_to root_url
    assert_equal 1, Account.count
    assert_equal 1, User.count
    assert_equal 1, Room.count
    assert parsed_cookies.signed[:session_token]
  end

  test "session creation failure discards a staged first-run avatar" do
    Session.stubs(:start!).raises(ActiveRecord::RecordInvalid.new(Session.new))

    assert_no_difference [
      -> { Account.count }, -> { User.count }, -> { Room.count }, -> { ActiveStorage::Blob.count }
    ] do
      assert_raises(ActiveRecord::RecordInvalid) do
        post first_run_url, params: { user: {
          name: "New Person", email_address: "avatar-retry@37signals.com",
          password: "secret123456", avatar: fixture_file_upload("moon.jpg", "image/jpeg")
        } }
      end
    end
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
