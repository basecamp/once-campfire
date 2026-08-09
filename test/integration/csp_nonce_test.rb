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

  test "a per-install ENV extra host is appended to its directive" do
    with_env "CSP_EXTRA_FRAME_SRC" => "https://player.vimeo.com https://www.youtube.com",
             "CSP_EXTRA_IMG_SRC"   => "https://cdn.example.test" do
      header = ActionDispatch::ContentSecurityPolicy.new { |p| CSP.apply(p) }.build

      assert_match %r{frame-src[^;]*\bhttps://player\.vimeo\.com\b}, header
      assert_match %r{frame-src[^;]*\bhttps://www\.youtube\.com\b}, header
      assert_match %r{img-src[^;]*\bhttps://cdn\.example\.test\b}, header
      # :self is preserved alongside the extras.
      assert_match %r{frame-src 'self'}, header
    end
  end

  test "a semicolon-separated ENV extra tokenizes into valid sources without raising" do
    # A plausible operator paste separates hosts with "; ". Because the nonce
    # forces a per-request policy build, a semicolon left inside a single source
    # token would make Rails raise InvalidDirectiveError on every request — a
    # site-wide 500 even in report-only mode. Splitting on ';' must yield both
    # hosts as valid tokens and never raise.
    with_env "CSP_EXTRA_FRAME_SRC" => "https://a.example; https://b.example" do
      header = nil
      assert_nothing_raised do
        header = ActionDispatch::ContentSecurityPolicy.new { |p| CSP.apply(p) }.build
      end

      assert_match %r{frame-src[^;]*\bhttps://a\.example\b}, header
      assert_match %r{frame-src[^;]*\bhttps://b\.example\b}, header
      # Both hosts share the one frame-src directive; the semicolon did not leak
      # a second directive into the policy.
      assert_equal 1, header.scan(/(?:^|;\s*)frame-src\b/).size,
        "Expected exactly one frame-src directive"
    end
  end

  test "directives default to :self only when no ENV extras are set" do
    with_env "CSP_EXTRA_FRAME_SRC" => nil, "CSP_EXTRA_IMG_SRC" => nil do
      header = ActionDispatch::ContentSecurityPolicy.new { |p| CSP.apply(p) }.build

      assert_match %r{frame-src 'self'(;|\z)}, header
    end
  end

  private
    def with_env(vars)
      original = {}
      vars.each_key { |k| original[k] = ENV.key?(k) ? ENV[k] : :__unset__ }
      vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      yield
    ensure
      original.each { |k, v| v == :__unset__ ? ENV.delete(k) : ENV[k] = v }
    end

    def report_only_nonce
      response.headers["Content-Security-Policy-Report-Only"].to_s[/'nonce-([^']+)'/, 1]
    end
end
