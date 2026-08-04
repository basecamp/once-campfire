require "test_helper"

class Oidc::FlowTest < ActiveSupport::TestCase
  setup do
    configure_oidc
    @browser_token = SecureRandom.urlsafe_base64(32)
  end

  test "atomically consumes a server-side flow only once and removes its secrets" do
    flow = start_flow

    consumed = Oidc::Flow.consume!(state: "state", browser_token: @browser_token)

    assert_equal "nonce", consumed.nonce
    assert_equal "verifier", consumed.pkce_verifier
    assert flow.reload.consumed_at?
    assert flow.state_digest.start_with?(Oidc::Flow::PROCESSING_STATE_PREFIX)
    assert_nil flow.nonce
    assert_nil flow.pkce_verifier
    assert_raises(Oidc::Flow::Invalid) do
      Oidc::Flow.consume!(state: "state", browser_token: @browser_token)
    end
  end

  test "finalizes processing in the guarded transaction and removes the flow" do
    flow = start_flow
    consumed = Oidc::Flow.consume!(state: "state", browser_token: @browser_token)

    result = consumed.finalize! { "committed" }

    assert_equal "committed", result
    assert_not Oidc::Flow.exists?(flow.id)
  end

  test "canceling processing prevents finalization" do
    start_flow
    consumed = Oidc::Flow.consume!(state: "state", browser_token: @browser_token)

    assert Oidc::Flow.cancel!(@browser_token)
    assert_raises(Oidc::Flow::Invalid) { consumed.finalize! { flunk "mutation ran after cancellation" } }
  end

  test "processing work still blocks another flow in the same browser" do
    start_flow
    Oidc::Flow.consume!(state: "state", browser_token: @browser_token)

    assert Oidc::Flow.pending_for?(@browser_token)
    assert_raises(Oidc::Flow::AlreadyInProgress) { start_flow(state: "second-state") }
  end

  test "allows only one pending flow for a browser" do
    start_flow

    assert_raises(Oidc::Flow::AlreadyInProgress) { start_flow(state: "second-state") }
  end

  test "binds consumption to the browser and exact OIDC configuration" do
    start_flow

    assert_raises(Oidc::Flow::Invalid) do
      Oidc::Flow.consume!(state: "state", browser_token: "another-browser")
    end

    configure_oidc("OIDC_CLIENT_SECRET" => "rotated-secret")
    assert_raises(Oidc::Flow::Invalid) do
      Oidc::Flow.consume!(state: "state", browser_token: @browser_token)
    end
  end

  test "retains the initiating session and linking operation" do
    linking_deadline = 2.minutes.from_now.change(usec: 0)
    flow = start_flow(
      initiating_session_id: sessions(:jz_chrome).id,
      linking_intent: {
        "session_id" => sessions(:jz_chrome).id,
        "return_to" => "https://campfire.example.com/users/me/profile",
        "expires_at" => linking_deadline.to_i
      }
    )

    consumed = Oidc::Flow.consume!(state: "state", browser_token: @browser_token)

    assert_equal "link", flow.operation
    assert_equal sessions(:jz_chrome).id, consumed.initiating_session_id
    assert_equal sessions(:jz_chrome).id, consumed.linking_session_id
    assert_equal "https://campfire.example.com/users/me/profile", consumed.return_to
    assert_equal linking_deadline, flow.expires_at
    assert_equal linking_deadline, consumed.expires_at
  end


  test "does not extend an expired linking authorization" do
    assert_raises(Oidc::Flow::Invalid) do
      start_flow(linking_intent: {
        "session_id" => sessions(:jz_chrome).id,
        "expires_at" => 1.second.ago.to_i
      })
    end

    assert_not Oidc::Flow.exists?
  end

  test "an expired flow no longer blocks a new initiation" do
    start_flow.update_column(:expires_at, 1.minute.ago)

    assert_nothing_raised { start_flow(state: "replacement-state") }
  end

  private
    def start_flow(state: "state", initiating_session_id: nil, linking_intent: nil)
      Oidc::Flow.start!(
        state:,
        nonce: "nonce",
        pkce_verifier: "verifier",
        browser_token: @browser_token,
        initiating_session_id:,
        linking_intent:
      )
    end
end
