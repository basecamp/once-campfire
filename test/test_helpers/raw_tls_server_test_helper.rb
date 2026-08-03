require "openssl"
require "socket"

module RawTlsServerTestHelper
  class RawTlsServer
    attr_reader :port

    def initialize(response)
      @response = response
      @tcp_server = TCPServer.new("127.0.0.1", 0)
      @port = @tcp_server.local_address.ip_port
      @ssl_server = OpenSSL::SSL::SSLServer.new(@tcp_server, self.class.ssl_context)
      @thread = Thread.new { serve }
    end

    def http_client
      Net::HTTP.new("localhost", port, nil).tap do |http|
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_NONE
        http.define_singleton_method(:ipaddr=) { |_address| }
      end
    end

    def close
      @tcp_server.close unless @tcp_server.closed?
      @thread.join(1)
      @thread.kill if @thread.alive?
    end

    class << self
      def ssl_context
        @ssl_context ||= begin
          key = OpenSSL::PKey::RSA.new(2048)
          certificate = OpenSSL::X509::Certificate.new
          certificate.version = 2
          certificate.serial = 1
          certificate.subject = OpenSSL::X509::Name.parse("/CN=localhost")
          certificate.issuer = certificate.subject
          certificate.public_key = key.public_key
          now = Time.now
          certificate.not_before = now - 1.hour
          certificate.not_after = now + 1.hour
          certificate.sign key, OpenSSL::Digest.new("SHA256")

          OpenSSL::SSL::SSLContext.new.tap do |context|
            context.cert = certificate
            context.key = key
          end
        end
      end
    end

    private
      def serve
        Thread.current.report_on_exception = false
        socket = @ssl_server.accept
        while (line = socket.gets)
          break if line == "\r\n"
        end
        if @response.respond_to?(:call)
          @response.call socket
        else
          socket.write @response
        end
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        nil
      ensure
        socket&.close
      end
  end

  def with_raw_tls_response(response)
    server = RawTlsServer.new(response)
    WebMock.disable!
    yield server
  ensure
    server&.close
    WebMock.enable!
    WebMock.disable_net_connect!
  end

  def oversized_raw_response_header
    raw_http_response "X-Oversized: #{"x" * RestrictedHTTP::ResponseHeaderGuard::MAXIMUM_LINE_BYTES}\r\n"
  end

  def excessive_raw_response_headers
    headers = Array.new(RestrictedHTTP::ResponseHeaderGuard::MAXIMUM_HEADER_LINES + 1) do |index|
      "X-Header-#{index}: x\r\n"
    end.join
    raw_http_response headers
  end

  private
    def raw_http_response(headers)
      "HTTP/1.1 200 OK\r\n#{headers}\r\n"
    end
end
