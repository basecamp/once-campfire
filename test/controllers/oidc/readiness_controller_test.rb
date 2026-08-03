require "test_helper"

class Oidc::ReadinessControllerTest < ActionDispatch::IntegrationTest
  test "reports disabled mode independently from liveness" do
    get oidc_readiness_check_url

    assert_response :success
    assert_equal({ "status" => "disabled" }, response.parsed_body)
  end

  test "reports required mode as unavailable until activation" do
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address)

    get oidc_readiness_check_url

    assert_response :service_unavailable
    assert_equal({ "status" => "not_ready" }, response.parsed_body)
  end

  test "reports enabled mode as unavailable without back-channel logout storage" do
    configure_oidc
    Oidc::LogoutToken.stubs(:ready?).returns(false)

    get oidc_readiness_check_url

    assert_response :service_unavailable
    assert_equal({ "status" => "not_ready" }, response.parsed_body)
  end

  test "reports rollback quarantine as unavailable even with OIDC disabled" do
    accounts(:signal).update!(oidc_transition_state: "rollback_prepared")

    get oidc_readiness_check_url

    assert_response :service_unavailable
    assert_equal({ "status" => "not_ready" }, response.parsed_body)
  end

  test "reports policy read uncertainty as unavailable" do
    Oidc.stubs(:rollback_prepared?).raises(Oidc::PolicyUnavailable, Oidc::POLICY_UNAVAILABLE_MESSAGE)

    get oidc_readiness_check_url

    assert_response :service_unavailable
    assert_equal({ "status" => "not_ready" }, response.parsed_body)
  end
end
