require "test_helper"

class ContentSecurityPolicyTest < ActionDispatch::IntegrationTest
  PAGE_PATH = "/"

  setup { sign_in :david }

  test "enforcing policy allows exactly the inline scripts the page carries" do
    get root_url
    follow_redirect! while response.redirect?

    policy = response.headers["Content-Security-Policy"]
    assert policy, "expected an enforcing Content-Security-Policy header"
    assert_nil response.headers["Content-Security-Policy-Report-Only"]
    assert_match "object-src 'none'", policy
    assert_match "base-uri 'self'", policy
    assert_no_match "unsafe-inline", policy
    assert_no_match "nonce-", policy

    script_src = policy[/script-src ([^;]+)/, 1].split
    inline = Nokogiri::HTML5(response.body).css("script").reject { |s| s["src"] || s["type"] == "text/template" }
    assert_operator inline.size, :>=, 2
    inline.each do |script|
      assert_includes script_src, "'sha256-#{Digest::SHA256.base64digest(script.text)}'", "inline #{script["type"]} script not allowed by hash"
    end
  end

  test "scripts may load from a configured asset host, however it's written" do
    {
      "https://cdn.example.test" => %r{\Ahttps://cdn\.example\.test\z},
      "cdn.example.test" => %r{\Ahttp://cdn\.example\.test\z},
      "//cdn.example.test" => %r{\Ahttp://cdn\.example\.test\z},
      "https://assets%d.example.test" => %r{\Ahttps://assets[0-3]\.example\.test\z},
      ->(source) { "https://one.example.test" } => %r{\Ahttps://one\.example\.test\z},
      ->(source, request) { "https://#{request.host}.example.test" } => %r{\Ahttps://www\.example\.com\.example\.test\z}
    }.each do |asset_host, expected_origin|
      with_asset_host(asset_host) do
        get PAGE_PATH
        follow_redirect! while response.redirect?
        assert_response :success

        script_src = response.headers["Content-Security-Policy"][/script-src ([^;]+)/, 1].split
        page = Nokogiri::HTML5(response.body)
        urls = JSON.parse(page.at_css("script[type=importmap]").text)["imports"].values +
          page.css("link[rel=modulepreload]").map { it["href"] } + page.css("script[src]").map { it["src"] }
        origins = urls.map { URI.join(request.base_url, it).origin }.uniq - [ request.base_url ]

        assert_not_empty origins, asset_host.inspect
        origins.each do |origin|
          assert_match expected_origin, origin, asset_host.inspect
          assert_includes script_src, origin, asset_host.inspect
        end
        assert_includes script_src, "'sha256-#{Digest::SHA256.base64digest(page.at_css("script[type=importmap]").text)}'", asset_host.inspect
      end
    end
  end

  test "the escape hatch boots without a policy" do
    output = IO.popen({ "DISABLE_CONTENT_SECURITY_POLICY" => "true" },
      [ "bin/rails", "runner", "print Rails.application.config.content_security_policy.inspect" ], chdir: Rails.root, err: File::NULL, &:read)

    assert_equal "nil", output
  end

  test "uploaded files are guarded on their way out" do
    assert_includes Rails.application.middleware.map(&:klass), UploadedScriptGuard
  end

  private
    def with_asset_host(asset_host)
      previous, ApplicationController.asset_host = ApplicationController.asset_host, asset_host
      Rails.application.importmap.send(:clear_cache)
      yield
    ensure
      ApplicationController.asset_host = previous
      Rails.application.importmap.send(:clear_cache)
    end
end
