require "test_helper"
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
