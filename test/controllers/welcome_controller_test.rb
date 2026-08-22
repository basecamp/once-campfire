require "test_helper"

class WelcomeControllerTest < ActionDispatch::IntegrationTest
  setup do
    sign_in :david
  end

  test "redirects to the first created visible room the user has access to" do
    get root_url

    assert_redirected_to room_url(users(:david).rooms.original)
  end

  test "redirects to the last room visited, if we have one" do
    cookies[:last_room] = rooms(:watercooler).id

    get root_url

    assert_redirected_to room_url(rooms(:watercooler))
  end

  test "unactivated required mode fails before authentication without deleting credentials" do
    current_session = Session.find_by!(token: parsed_cookies.signed[:session_token])
    configure_oidc("OIDC_MODE" => "required", "OIDC_BREAK_GLASS_EMAIL" => users(:jason).email_address)

    assert_no_difference -> { Session.count } do
      get root_url
    end

    assert_response :service_unavailable
    assert Session.exists?(current_session.id)
  end

  test "rollback quarantine is enforced even with OIDC disabled" do
    accounts(:signal).update!(oidc_transition_state: "rollback_prepared")

    assert_no_difference -> { Session.count } do
      get root_url
    end

    assert_response :service_unavailable
  end
end
