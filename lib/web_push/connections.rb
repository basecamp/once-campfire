# This is in lib so we can use it in a thread pool without the Rails executor
#
# Keeps TLS connections to push services open between deliveries, so a push doesn't pay for a new TCP and TLS
# handshake every time. Each connection is pinned to the address Push::Subscription resolved and guarded for the
# delivery that opened it, and is handed out again only to a delivery whose own resolution, just made, returned that
# same address for the same host. Net::HTTP reconnects to its pinned address, never to a new lookup of the host.
class WebPush::Connections
  class ConnectionLost < StandardError; end

  # Net::HTTP checks an idle connection, and reconnects if the push service closed it, just before writing the
  # request. Until then a dead connection can be replaced without sending the push twice.
  module WriteTracking
    attr_reader :request_written

    private def begin_transport(...)
      @request_written = false
      super.tap { @request_written = true }
    end
  end

  def initialize(keep_alive_timeout: 30)
    @keep_alive_timeout = keep_alive_timeout
    @idle = Hash.new { |idle, address| idle[address] = [] }
    @mutex = Mutex.new
    @pid = Process.pid
  end

  def request(http, request)
    unless http.ipaddr && !http.proxy? && http.use_ssl? && !http.started?
      raise ArgumentError, "Only new, direct TLS connections pinned to an address are pooled"
    end
    address = [ http.address, http.port, http.ipaddr ]

    if idle = checkout(address)
      response = begin
        idle.request(request)
      rescue IOError, SystemCallError, OpenSSL::SSL::SSLError => error
        close(idle)
        # The push service may have it: don't send it twice, and don't report a closed connection as a TLS failure
        raise ConnectionLost, "#{error.class}: #{error.message}" if idle.request_written
      end
      return response.tap { checkin(address, idle) } if response
    end

    http.extend WriteTracking
    http.keep_alive_timeout = @keep_alive_timeout
    http.start
    http.request(request).tap { checkin(address, http) }
  end

  def shutdown
    @mutex.synchronize do
      forget_after_fork
      @shut_down = true
      @idle.each_value { |connections| connections.each { |http, _| close(http) } }
      @idle.clear
    end
  end

  private
    def checkout(address)
      @mutex.synchronize do
        forget_after_fork
        close_expired
        @idle[address].pop&.first
      end
    end

    def checkin(address, http)
      @mutex.synchronize do
        close_expired
        if @shut_down
          close(http)
        else
          @idle[address].push [ http, now ]
        end
      end
    end

    # A forked process must not write on its parent's TLS sessions. They're left to the parent, not closed.
    def forget_after_fork
      unless @pid == Process.pid
        @idle = Hash.new { |idle, address| idle[address] = [] }
        @pid = Process.pid
      end
    end

    def close_expired
      @idle.each_value do |connections|
        connections.reject! { |http, idle_since| (now - idle_since > @keep_alive_timeout).tap { |expired| close(http) if expired } }
      end
      @idle.delete_if { |_, connections| connections.empty? }
    end

    def close(http)
      http.finish if http.started?
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
end
