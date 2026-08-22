require "test_helper"
require "open3"
require "rbconfig"
require "socket"
require "timeout"
require "tmpdir"

class Oidc::ThrusterPolicyTest < ActiveSupport::TestCase
  REQUIRED_VERSION = Gem::Version.new("0.1.23")

  test "pins a Thruster release with HTTP host-policy enforcement" do
    assert_equal REQUIRED_VERSION, Gem.loaded_specs.fetch("thruster").version
    assert_match(/^gem "thruster", "= #{Regexp.escape(REQUIRED_VERSION.to_s)}"$/,
      Rails.root.join("Gemfile").read)
  end

  test "production launcher disables request logging before Thruster starts" do
    source = Rails.root.join("bin/start-web").read
    assert_match(/^export LOG_REQUESTS=false$/, source)
    assert_match(/^export THRUSTER_LOG_REQUESTS=false$/, source)
  end

  test "production launcher rejects ambiguous DISABLE_SSL values" do
    _stdout, stderr, status = Open3.capture3(
      { "DISABLE_SSL" => "false", "TLS_DOMAIN" => nil, "THRUSTER_TLS_DOMAIN" => nil },
      Rails.root.join("bin/start-web").to_s
    )

    assert_not status.success?
    assert_match "DISABLE_SSL must be exactly true when set", stderr
  end

  test "production launcher requires a nonempty effective built-in TLS domain" do
    [
      { "TLS_DOMAIN" => nil, "THRUSTER_TLS_DOMAIN" => nil },
      { "TLS_DOMAIN" => "campfire.example.com", "THRUSTER_TLS_DOMAIN" => "  ,  " }
    ].each do |environment|
      _stdout, stderr, status = Open3.capture3(
        environment.merge("DISABLE_SSL" => nil), Rails.root.join("bin/start-web").to_s
      )

      assert_not status.success?
      assert_match "requires a nonempty effective TLS_DOMAIN", stderr
    end
  end

  test "production launcher accepts the external HTTPS container contract" do
    Dir.mktmpdir("campfire-start-web") do |root|
      bin_path = File.join(root, "bin")
      FileUtils.mkdir_p bin_path
      FileUtils.cp Rails.root.join("bin/start-web"), File.join(bin_path, "start-web")
      File.write File.join(bin_path, "start-app"), <<~'SH'
        #!/bin/sh
        printf 'PORT=%s\n' "$PORT"
        printf 'CAMPFIRE_INTERNAL_TLS_PROXY=%s\n' "${CAMPFIRE_INTERNAL_TLS_PROXY-unset}"
      SH
      FileUtils.chmod 0o755, Dir[File.join(bin_path, "*")]

      stdout, stderr, status = Open3.capture3(
        {
          "DISABLE_SSL" => "true",
          "TLS_DOMAIN" => nil,
          "THRUSTER_TLS_DOMAIN" => nil,
          "CAMPFIRE_INTERNAL_TLS_PROXY" => "stale"
        },
        File.join(bin_path, "start-web"), chdir: root
      )

      assert status.success?, stderr
      assert_equal "PORT=80\nCAMPFIRE_INTERNAL_TLS_PROXY=unset\n", stdout
    end
  end

  test "external production HTTPS forces SSL and keeps the session cookie secure without OIDC" do
    probe = production_transport_probe("DISABLE_SSL" => "true")

    assert_equal true, probe.fetch("force_ssl")
    assert_equal false, probe.fetch("assume_ssl")
    assert_equal true, probe.fetch("secure_session")
    assert_empty probe.fetch("hosts")
    assert_equal 200, probe.fetch("health_status_without_forwarded_headers")
    assert_equal Oidc::HEALTH_PATHS, probe.fetch("health_redirect_exclusions").keys
    assert probe.fetch("health_redirect_exclusions").values.all?
  end

  test "trusted external HTTPS admits health checks without forwarded headers" do
    probe = production_transport_probe(
      "DISABLE_SSL" => "true",
      "OIDC_MODE" => "optional",
      "OIDC_ISSUER" => "https://idp.example.com",
      "OIDC_CLIENT_ID" => "campfire",
      "OIDC_CLIENT_SECRET" => "client-secret",
      "OIDC_REDIRECT_URI" => "https://campfire.example.com/auth/openid_connect/callback",
      "OIDC_TRUSTED_PROXY_CIDRS" => "127.0.0.1/32",
      "TLS_DOMAIN" => "campfire.example.com"
    )

    assert_equal 200, probe.fetch("health_status_without_forwarded_headers")
    assert probe.fetch("health_redirect_exclusions").values.all?
  end

  test "OIDC-disabled built-in TLS admits only configured TLS hosts" do
    probe = production_transport_probe("TLS_DOMAIN" => "campfire.example.com")

    assert_equal true, probe.fetch("force_ssl")
    assert_equal true, probe.fetch("assume_ssl")
    assert_equal true, probe.fetch("secure_session")
    assert_equal [ "campfire.example.com" ], probe.fetch("hosts")
    assert_equal 421, probe.fetch("blocked_status")
    assert_equal 200, probe.fetch("allowed_status")
    assert_equal true, probe.fetch("blocked_security_headers")
  end

  test "Thruster redirects only policy-allowed HTTP hosts" do
    with_thruster do |port|
      canonical = http_request(port, host: "campfire.example.com", path: "/session/new?from=http")
      rejected = http_request(port, host: "attacker.example.com", path: "/session/new")

      assert_equal 301, canonical.fetch(:status)
      assert_equal "https://campfire.example.com/session/new?from=http", canonical.fetch(:headers).fetch("location")
      assert_equal 421, rejected.fetch(:status)
      assert_nil rejected.fetch(:headers)["location"]
    end
  end

  private
    def production_transport_probe(overrides)
      script = <<~'RUBY'
        require_relative "config/environment"

        config = Rails.application.config
        result = {
          force_ssl: config.force_ssl,
          assume_ssl: config.assume_ssl,
          secure_session: config.session_options[:secure],
          hosts: config.hosts
        }
        request = Rack::MockRequest.new(Rails.application)
        health_environment = {
          "REMOTE_ADDR" => "127.0.0.1",
          "HTTP_HOST" => "campfire.example.com"
        }
        result[:health_status_without_forwarded_headers] = request.get(
          "/up", health_environment
        ).status
        redirect_exclusion = config.ssl_options.dig(:redirect, :exclude)
        result[:health_redirect_exclusions] = Oidc::HEALTH_PATHS.index_with do |path|
          redirect_exclusion&.call(ActionDispatch::Request.new(
            Rack::MockRequest.env_for(path)
          ))
        end
        if config.hosts.any?
          https = { "rack.url_scheme" => "https", "HTTPS" => "on" }
          blocked = request.get("/up", https.merge("HTTP_HOST" => "attacker.example.com"))
          allowed = request.get("/up", https.merge("HTTP_HOST" => config.hosts.first))
          result[:blocked_status] = blocked.status
          result[:allowed_status] = allowed.status
          result[:blocked_security_headers] = Oidc::DEFAULT_SECURITY_HEADERS.all? do |name, value|
            blocked.headers[name] == value
          end
        end
        puts "TRANSPORT_PROBE=#{JSON.generate(result)}"
      RUBY
      environment = {
        "RAILS_ENV" => "production",
        "SECRET_KEY_BASE" => "0" * 64,
        "OIDC_MODE" => "disabled",
        "SKIP_TELEMETRY" => "true",
        "DISABLE_SSL" => nil,
        "TLS_DOMAIN" => nil,
        "THRUSTER_TLS_DOMAIN" => nil
      }.merge(overrides)
      stdout, stderr, status = Open3.capture3(
        environment, RbConfig.ruby, "-e", script, chdir: Rails.root.to_s
      )
      assert status.success?, stderr
      line = stdout.lines.find { _1.start_with?("TRANSPORT_PROBE=") }
      assert line, stdout
      JSON.parse line.delete_prefix("TRANSPORT_PROBE=")
    end

    def with_thruster
      http_port, https_port, target_port = available_ports(3)
      Dir.mktmpdir("campfire-thruster-policy") do |storage_path|
        environment = {
          "TLS_DOMAIN" => "campfire.example.com",
          "HTTP_PORT" => http_port.to_s,
          "HTTPS_PORT" => https_port.to_s,
          "TARGET_PORT" => target_port.to_s,
          "STORAGE_PATH" => storage_path,
          "LOG_REQUESTS" => "false"
        }
        command = [ Gem.bin_path("thruster", "thrust"), RbConfig.ruby, "-e", "sleep 30" ]
        pid = Process.spawn(environment, *command, pgroup: true, out: File::NULL, err: File::NULL)
        wait_for_port http_port
        yield http_port
      ensure
        terminate_process_group pid
      end
    end

    def available_ports(count)
      servers = count.times.map { TCPServer.new("127.0.0.1", 0) }
      servers.map { _1.local_address.ip_port }
    ensure
      servers&.each(&:close)
    end

    def wait_for_port(port)
      Timeout.timeout(10) do
        loop do
          TCPSocket.open("127.0.0.1", port, &:close)
          break
        rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH
          sleep 0.05
        end
      end
    end

    def http_request(port, host:, path:)
      raw = TCPSocket.open("127.0.0.1", port) do |socket|
        socket.write "GET #{path} HTTP/1.1\r\nHost: #{host}\r\nConnection: close\r\n\r\n"
        socket.read
      end
      header = raw.split("\r\n\r\n", 2).first
      lines = header.split("\r\n")
      {
        status: lines.shift.split.fetch(1).to_i,
        headers: lines.to_h do |line|
          name, value = line.split(":", 2)
          [ name.downcase, value.to_s.strip ]
        end
      }
    end

    def terminate_process_group(pid)
      return unless pid

      Process.kill "TERM", -pid
      Timeout.timeout(5) { Process.wait(pid) }
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    rescue Timeout::Error
      Process.kill "KILL", -pid
      Process.wait(pid)
    end
end
