require "test_helper"

class FetchMetadataTest < ActionDispatch::IntegrationTest
  setup do
    host! "once.campfire.test"
    @previous_exceptions = Rails.application.env_config["action_dispatch.show_exceptions"]
    Rails.application.env_config["action_dispatch.show_exceptions"] = :rescuable
    @previous_forgery = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
  end

  teardown do
    ActionController::Base.allow_forgery_protection = @previous_forgery
    Rails.application.env_config["action_dispatch.show_exceptions"] = @previous_exceptions
  end

  test "login and authenticated forms have no token fields" do
    get new_session_url
    assert_response :success
    assert_select 'meta[name="csrf-token"]', count: 0
    assert_select 'input[name="authenticity_token"]', count: 0
    sign_in :david
    get room_url(rooms(:watercooler))
    assert_response :success
    assert_select 'meta[name="csrf-token"]', count: 0
    assert_select 'input[name="authenticity_token"]', count: 0
  end

  test "HTTPS login accepts browser metadata without a token" do
    https!
    %w[ same-origin same-site ].each do |site|
      reset!
      host! "once.campfire.test"
      https!
      post session_url, params: credentials, headers: {
        "Sec-Fetch-Site" => site, "Origin" => "https://once.campfire.test" }
      assert_response :redirect
      assert cookies["session_token"].present?
    end
  end

  test "HTTPS writes reject missing metadata even with a legacy token parameter" do
    https!
    assert_no_difference "Session.count" do
      post session_url, params: credentials.merge(authenticity_token: "old token"), headers: { "Origin" => "https://once.campfire.test" }
    end
    assert_response :unprocessable_entity
  end

  test "cross-site none and malformed metadata cannot sign in over HTTP or HTTPS" do
    [ false, true ].each do |tls|
      https! tls
      %w[ cross-site none garbage ].each do |site|
        assert_no_difference "Session.count" do
          post session_url, params: credentials, headers: { "Sec-Fetch-Site" => site }
        end
        assert_response :unprocessable_entity
      end
    end
  end

  test "provided foreign and null origins fail even with same-site metadata" do
    %w[ https://foreign.example null ].each do |origin|
      assert_no_difference "Session.count" do
        post session_url, params: credentials, headers: { "Sec-Fetch-Site" => "same-site", "Origin" => origin }
      end
      assert_response :unprocessable_entity
    end
  end

  test "plain HTTP retains the missing-header fallback" do
    post session_url, params: credentials, headers: { "Origin" => "http://once.campfire.test" }
    assert_response :redirect
    assert cookies["session_token"].present?
  end

  test "cross-site reads remain available and method-overridden writes stay protected" do
    get new_session_url, headers: { "Sec-Fetch-Site" => "cross-site" }
    assert_response :success
    sign_in :david
    assert_no_difference "Room.count" do
      post room_path(rooms(:watercooler)), params: { _method: "delete" }, headers: { "Sec-Fetch-Site" => "cross-site" }
    end
    assert_response :unprocessable_entity
  end

  private
    def credentials
      { email_address: users(:david).email_address, password: "secret123456" }
    end
end
