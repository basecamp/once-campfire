require "test_helper"

class Scim::ReadinessControllerTest < ActionDispatch::IntegrationTest
  test "reports disabled independently from liveness" do
    get scim_readiness_check_url

    assert_response :success
    assert_equal({ "status" => "disabled" }, response.parsed_body)
  end

  test "reports an enabled migrated configuration as ready" do
    configure_oidc
    configure_scim

    get scim_readiness_check_url

    assert_response :success
    assert_equal({ "status" => "ready" }, response.parsed_body)
  end

  test "fails closed when storage or policy is not ready" do
    configure_oidc
    configure_scim
    Scim.stubs(:ready?).returns(false)

    get scim_readiness_check_url

    assert_response :service_unavailable
    assert_equal({ "status" => "not_ready" }, response.parsed_body)
  end

  test "fails closed when the shared mutation-fence filesystem is not ready" do
    configure_oidc
    configure_scim
    User::MutationFence.stubs(:ready?).returns(false)

    get scim_readiness_check_url

    assert_response :service_unavailable
    assert_equal({ "status" => "not_ready" }, response.parsed_body)
  end
end
