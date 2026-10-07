module PushServiceTestHelper
  # A push service on 127.0.0.1 for delivery tests: TLS with a certificate for HOST from a test CA that the
  # process trusts, HTTP/1.1 keep-alive. HOST doesn't resolve, so a delivery that looked it up instead of
  # using its pinned address would fail.
  HOST = "push.test"
  IP = "127.0.0.1"

  class Server
    attr_reader :port

    # status: the answer to every request.
    # hang_up_after_response: :fin or :close_notify to hang up after each answer, as an idle timeout would.
    # drop_request: ->(number) whether to hang up after reading that request, without answering it.
    # certificate: ->(connection) the name its certificate is for, HOST unless told otherwise.
    def initialize(status: "201 Created", hang_up_after_response: nil, drop_request: ->(_) { false }, certificate: ->(_) { HOST })
      @status, @hang_up_after_response, @drop_request, @certificate = status, hang_up_after_response, drop_request, certificate
      @connections, @requests, @closed = 0, [], Queue.new
      @mutex = Mutex.new
      @listener = TCPServer.new(IP, 0)
      @port = @listener.addr[1]
      @thread = Thread.new { loop { serve(@listener.accept) } rescue IOError }
    end

    def connections = @mutex.synchronize { @connections }
    def requests = @mutex.synchronize { @requests.dup }

    # Whether a connection to it closed, waiting for that up to the given seconds.
    def hung_up?(within: 5)
      !!@closed.pop(timeout: within)
    end

    def stop
      @listener.close
      @thread.join
    end

    private
      def serve(socket)
        connection = @mutex.synchronize { @connections += 1 }
        Thread.new do
          tls = OpenSSL::SSL::SSLSocket.new(socket, PushServiceTestHelper.context_for(@certificate.(connection))).tap(&:accept)
          while (request_line = tls.gets("\r\n"))
            length = 0
            while (header = tls.gets("\r\n")) != "\r\n"
              length = header.split(":", 2).last.to_i if header.downcase.start_with?("content-length:")
            end
            tls.read(length)
            number = @mutex.synchronize { @requests << request_line.split[1]; @requests.size }
            break if @drop_request.(number)
            tls.write "HTTP/1.1 #{@status}\r\nContent-Length: 0\r\n\r\n"
            if @hang_up_after_response
              tls.close if @hang_up_after_response == :close_notify
              break
            end
          end
        rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
        ensure
          socket.close
          @closed << true
        end
      end
  end

  class << self
    def context_for(name)
      @contexts ||= {}
      @contexts[name] ||= OpenSSL::SSL::SSLContext.new.tap do |context|
        context.key = OpenSSL::PKey::EC.generate("prime256v1")
        context.cert = sign(subject: "CN=#{name}", key: context.key, ca: ca, ca_key: ca_key) do |extensions|
          [ extensions.create_extension("subjectAltName", "DNS:#{name}") ]
        end
      end
    end

    private
      def ca_key
        @ca_key ||= OpenSSL::PKey::EC.generate("prime256v1")
      end

      def ca
        @ca ||= sign(subject: "CN=Push service test CA", key: ca_key, ca_key: ca_key) do |extensions|
          [ extensions.create_extension("basicConstraints", "CA:TRUE", true), extensions.create_extension("keyUsage", "keyCertSign", true) ]
        end.tap { OpenSSL::SSL::SSLContext::DEFAULT_CERT_STORE.add_cert(it) }
      end

      def sign(subject:, key:, ca_key:, ca: nil)
        OpenSSL::X509::Certificate.new.tap do |certificate|
          certificate.version, certificate.serial = 2, SecureRandom.random_number(1 << 64)
          certificate.subject = OpenSSL::X509::Name.parse(subject)
          certificate.issuer = ca ? ca.subject : certificate.subject
          certificate.public_key = key
          certificate.not_before, certificate.not_after = 1.minute.ago, 1.hour.from_now
          extensions = OpenSSL::X509::ExtensionFactory.new(ca || certificate, certificate)
          yield(extensions).each { certificate.add_extension(it) }
          certificate.sign(ca_key, "SHA256")
        end
      end
  end

  private
    def with_push_service(**options)
      WebMock.disable!
      server = Server.new(**options)
      yield server
    ensure
      server&.stop
      WebMock.enable!
    end

    # Built as WebPush::PersistentRequest builds it for a delivery.
    def pinned_connection(server, ip = IP)
      Net::HTTP.new(HOST, server.port, nil).tap do |http|
        http.ipaddr = ip
        http.use_ssl = true
      end
    end

    def push_request(path = "/push")
      Net::HTTP::Post.new(path).tap { it.body = "payload" }
    end
end
