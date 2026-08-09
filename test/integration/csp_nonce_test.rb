require "test_helper"

class CspNonceTest < ActionDispatch::IntegrationTest
  test "policy is delivered Report-Only, not enforced" do
    sign_in :david
    get root_url
    follow_redirect!  # root redirects to the last room

    assert_response :success
    assert response.headers["Content-Security-Policy-Report-Only"].present?,
      "Expected a Report-Only CSP header"
    assert_nil response.headers["Content-Security-Policy"],
      "Policy must not be enforced yet"
  end

  test "nonce is stable across requests so Turbo restores don't trip CSP" do
    sign_in :david

    get root_url
    nonce1 = report_only_nonce

    get root_url
    nonce2 = report_only_nonce

    assert nonce1.present?, "Expected a nonce in the Report-Only CSP header"
    assert_equal nonce1, nonce2, "Nonce must be stable across requests"
  end

  test "client-set identifier still yields an unpredictable HMAC nonce" do
    fake_id = "attacker-controlled-value"
    cookies[CSP::Nonce::COOKIE] = fake_id

    get root_url
    nonce = report_only_nonce

    assert_equal CSP::Nonce.hmac(fake_id), nonce,
      "Nonce must be HMAC-SHA256 of the identifier keyed by secret_key_base"
  end

  test "importmap script tag carries the nonce" do
    sign_in :david
    get root_url
    follow_redirect!  # root redirects to the last room

    assert_response :success
    nonce = report_only_nonce
    assert_select "script[type='importmap'][nonce=?]", nonce
  end

  private
    def report_only_nonce
      response.headers["Content-Security-Policy-Report-Only"].to_s[/'nonce-([^']+)'/, 1]
    end
end
