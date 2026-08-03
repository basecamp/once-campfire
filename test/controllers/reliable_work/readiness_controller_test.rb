require "test_helper"

class ReliableWork::ReadinessControllerTest < ActionDispatch::IntegrationTest
  test "ready without required deletion work" do
    get reliable_work_readiness_check_url

    assert_response :success
    assert_equal({ "status" => "ready", "pending_required_deletions" => 0 }, response.parsed_body)
  end

  test "not ready while required deletion remains pending" do
    User.any_instance.stubs(:disconnect_remote_connections)
    users(:kevin).ban_by! actor: users(:david)

    get reliable_work_readiness_check_url

    assert_response :service_unavailable
    assert_equal "not_ready", response.parsed_body.fetch("status")
    assert_equal 1, response.parsed_body.fetch("pending_required_deletions")
  end
end
