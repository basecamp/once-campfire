require "test_helper"

class Oidc::BackChannelLogoutsControllerTest < ActionDispatch::IntegrationTest
  setup do
    configure_oidc
    host! Oidc.configuration.redirect_host
    https!
  end

  test "consumes one form-encoded logout token" do
    Oidc::LogoutToken.expects(:consume!).with("signed-logout-token")

    post oidc_back_channel_logout_path, params: { logout_token: "signed-logout-token" }

    assert_response :success
    assert_empty response.body
    assert_equal "no-store", response.headers.fetch("Cache-Control")
  end

  test "accepts unrelated form parameters" do
    Oidc::LogoutToken.expects(:consume!).with("signed")

    post oidc_back_channel_logout_path,
      params: { logout_token: "signed", iss: "provider-hint", events: "ignored", _method: "delete" }

    assert_response :success
    assert_equal "no-store", response.headers.fetch("Cache-Control")
  end

  test "rejects missing duplicate query and non-form logout tokens" do
    Oidc::LogoutToken.expects(:consume!).never

    post oidc_back_channel_logout_path, params: {}
    assert_response :bad_request

    post oidc_back_channel_logout_path,
      params: "logout_token=first&unrelated=value&logout_token=second",
      headers: { "Content-Type" => "application/x-www-form-urlencoded" }
    assert_response :bad_request

    post "#{oidc_back_channel_logout_path}?logout_token=credential"
    assert_response :bad_request

    post oidc_back_channel_logout_path,
      params: { logout_token: "signed" }.to_json,
      headers: { "Content-Type" => "application/json" }
    assert_response :bad_request

    assert_equal "no-store", response.headers.fetch("Cache-Control")
  end

  test "returns generic bad requests for invalid and replayed tokens" do
    [
      Oidc::LogoutTokenVerifier::Invalid.new("provider details"),
      Oidc::LogoutToken::Replay.new("provider details")
    ].each do |error|
      Oidc::LogoutToken.stubs(:consume!).raises(error)

      post oidc_back_channel_logout_path, params: { logout_token: "signed" }

      assert_response :bad_request
      assert_not_includes response.body, "provider details"
    end
  end

  test "fails closed when verification or persistence is unavailable" do
    [
      Oidc::LogoutTokenVerifier::Unavailable.new("provider details"),
      ActiveRecord::StatementInvalid.new("database details")
    ].each do |error|
      Oidc::LogoutToken.stubs(:consume!).raises(error)

      post oidc_back_channel_logout_path, params: { logout_token: "signed" }

      assert_response :service_unavailable
      assert_empty response.body
    end
  end

  test "is unavailable when OIDC is disabled" do
    Oidc.configuration = Oidc::Configuration.new({})
    Oidc::LogoutToken.expects(:consume!).never

    post oidc_back_channel_logout_path, params: { logout_token: "signed" }

    assert_response :not_found
  end

  test "rate limits before verification and fails closed when its store is unavailable" do
    Oidc::LogoutToken.expects(:consume!).never
    Rails.cache.stubs(:increment).returns(SecurityEndpointRequestGuard::LOGOUT_REQUEST_LIMIT + 1)

    post oidc_back_channel_logout_path, params: { logout_token: "signed" }
    assert_response :too_many_requests

    Rails.cache.stubs(:increment).returns(nil)
    post oidc_back_channel_logout_path, params: { logout_token: "signed" }
    assert_response :service_unavailable
  end


  test "rejects an oversized body before logout-token parsing or verification" do
    Oidc::LogoutToken.expects(:consume!).never

    post oidc_back_channel_logout_path,
      params: "x" * (SecurityEndpointRequestGuard::LOGOUT_BODY_BYTES + 1),
      headers: { "Content-Type" => "application/x-www-form-urlencoded" }

    assert_response :content_too_large
    assert_equal "no-store", response.headers.fetch("Cache-Control")
  end
end
