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
    assert_equal "www.example.com/service-worker.js", policy[/worker-src ([^;]+)/, 1]

    script_src = policy[/script-src ([^;]+)/, 1].split
    assert_not_includes script_src, "'self'"
    assert_includes script_src, "www.example.com/assets/"
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
        origins.each { assert_match expected_origin, it, asset_host.inspect }
        assert_scripts_allowed_by_path script_src, urls.map { URI.join(request.base_url, it).to_s }, asset_host.inspect
        assert_includes script_src, "'sha256-#{Digest::SHA256.base64digest(page.at_css("script[type=importmap]").text)}'", asset_host.inspect
      end
    end
  end

  test "an asset host whose path contains the asset directory is limited to the directory it serves" do
    with_asset_host("https://cdn.example.test/assets") do
      get PAGE_PATH
      follow_redirect! while response.redirect?

      script_src = response.headers["Content-Security-Policy"][/script-src ([^;]+)/, 1].split
      assert_includes script_src, "https://cdn.example.test/assets/assets/"
      assert_not allowed_by_path?(script_src, "https://cdn.example.test/assets/rails/active_storage/blobs/proxy/x/upload.js")
    end
  end

  test "import locations resolve independently against the request origin" do
    host! "www.example.com:8443"
    https!

    with_relative_url_root("/chat") do
      urls = [
        "https://cdn.example.test/assets/chat/assets/first.js",
        "/chat/assets/application.js",
        "https://www.example.com:8443/chat/assets/same-origin.js",
        "//cdn.example.test/chat/assets/external.js",
        "/chat/assets/nested/../module.js?version=1#entry",
        "/chat/assets/../../uploads/upload.js",
        "uploads/relative.js?version=1#entry",
        "/outside.js?path=/chat/assets/ignored.js",
        "/chat/assets/%2e%2e/encoded.js",
        "/mirror/chat/assets/nested/chat/assets/last.js"
      ]
      importmap = JSON.generate("imports" => urls.each_with_index.to_h { |url, i| [ "script#{i}", url ] })
      Rails.application.importmap.stubs(:to_json).returns(importmap)

      get new_session_path
      assert_response :success

      locations = response.headers["Content-Security-Policy"][/script-src ([^;]+)/, 1].split.reject { it.start_with?("'sha256-") }
      assert_equal [
        "https://cdn.example.test/assets/chat/assets/",
        "www.example.com:8443/chat/assets/",
        "https://cdn.example.test/chat/assets/",
        "www.example.com:8443/uploads/upload.js",
        "www.example.com:8443/uploads/relative.js",
        "www.example.com:8443/outside.js",
        "www.example.com:8443/mirror/chat/assets/nested/chat/assets/"
      ], locations
    end
  end

  test "the sign-in page is limited to the asset directory too" do
    cookies.delete(:session_token)
    get new_session_url
    assert_response :success

    script_src = response.headers["Content-Security-Policy"][/script-src ([^;]+)/, 1].split
    assert_not_includes script_src, "'self'"
    assert_includes script_src, "www.example.com/assets/"
  end

  test "scripts are limited to the asset directory under a relative root" do
    with_relative_url_root("/chat") do
      get PAGE_PATH
      follow_redirect! while response.redirect?
      assert_response :success

      script_src = response.headers["Content-Security-Policy"][/script-src ([^;]+)/, 1].split
      page = Nokogiri::HTML5(response.body)
      urls = JSON.parse(page.at_css("script[type=importmap]").text)["imports"].values + page.css("link[rel=modulepreload]").map { it["href"] }

      assert urls.all? { it.start_with?("/chat/assets/") }, urls.inspect
      assert_includes script_src, "www.example.com/chat/assets/"
      assert_scripts_allowed_by_path script_src, urls.map { URI.join(request.base_url, it).to_s }
    end
  end

  test "this origin's sources keep a non-default port and take the page's scheme" do
    host! "www.example.com:8443"
    get PAGE_PATH
    follow_redirect! while response.redirect?

    policy = response.headers["Content-Security-Policy"]
    assert_includes policy[/script-src ([^;]+)/, 1].split, "www.example.com:8443/assets/"
    assert_equal "www.example.com:8443/service-worker.js", policy[/worker-src ([^;]+)/, 1]
  end

  test "uploads can't load as scripts" do
    get PAGE_PATH
    follow_redirect! while response.redirect?

    script_src = response.headers["Content-Security-Policy"][/script-src ([^;]+)/, 1].split
    blob = ActiveStorage::Blob.create_and_upload!(io: StringIO.new("alert(1)"), filename: "upload.js", content_type: "text/javascript")

    disk_url = ActiveStorage::Current.set(url_options: { protocol: "http", host: "www.example.com" }) { blob.url }

    [ rails_blob_url(blob), rails_blob_url(blob, disposition: :inline), rails_storage_proxy_url(blob), disk_url ].each do |url|
      assert_not allowed_by_path?(script_src, url), "#{url} allowed by #{script_src.inspect}"
    end
  end

  test "with the policy turned off, pages send none" do
    without_policy do
      get PAGE_PATH
      follow_redirect! while response.redirect?

      assert_response :success
      assert_nil response.headers["Content-Security-Policy"]
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
    # What DISABLE_CONTENT_SECURITY_POLICY=true leaves at boot: no application policy
    def without_policy
      previous = Rails.application.env_config.delete("action_dispatch.content_security_policy")
      yield
    ensure
      Rails.application.env_config["action_dispatch.content_security_policy"] = previous
    end

    # Every page script is allowed by a source with a path, never by a bare origin
    def assert_scripts_allowed_by_path(script_src, urls, message = nil)
      assert_empty script_src.grep(%r{\A([a-z]+://)?[^/']+/?\z}), message
      urls.each { assert allowed_by_path?(script_src, it), "#{it} not allowed by #{script_src.inspect} #{message}" }
    end

    # CSP source matching on a first request: 'self' and a bare origin match any
    # path, a path ending in / matches as a prefix, any other path exactly. A
    # source without a scheme takes the page's.
    def allowed_by_path?(script_src, url)
      url = URI(url)
      script_src.any? do |source|
        unless source.start_with?("'") && source != "'self'"
          source = URI(source == "'self'" ? request.base_url : (source.include?("://") ? source : "#{request.scheme}://#{source}"))
        end
        source.is_a?(URI) && source.origin == url.origin &&
          (source.path.empty? || (source.path.end_with?("/") ? url.path.start_with?(source.path) : url.path == source.path))
      end
    end

    def with_relative_url_root(root)
      previous, ApplicationController.config.relative_url_root = ApplicationController.config.relative_url_root, root
      Rails.application.importmap.send(:clear_cache)
      yield
    ensure
      ApplicationController.config.relative_url_root = previous
      Rails.application.importmap.send(:clear_cache)
    end

    def with_asset_host(asset_host)
      previous, ApplicationController.asset_host = ApplicationController.asset_host, asset_host
      Rails.application.importmap.send(:clear_cache)
      yield
    ensure
      ApplicationController.asset_host = previous
      Rails.application.importmap.send(:clear_cache)
    end
end
