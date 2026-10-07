# This is in lib so we can use it in a thread pool without the Rails executor
#
# Keeps TLS connections to push services open between deliveries, so a push doesn't pay for a new TCP and TLS
# handshake every time. Each connection is pinned to the address Push::Subscription resolved and guarded for the
# delivery that opened it, and is handed out again only to a delivery whose own resolution, just made, returned that
# same address for the same host. Net::HTTP reconnects to its pinned address, never to a new lookup of the host.
class WebPush::Connections
  class ConnectionLost < StandardError; end
  class StaleConnection < StandardError; end

  # Where a request failed. Before writing it, Net::HTTP checks an idle connection (:checking) and connects again
  # if the push service closed it (:connecting); then it writes (:sent). Only a failed check means a dead idle
  # connection that a new one can replace without sending the push twice.
  module Stages
    attr_reader :stage

    private
      def begin_transport(...)
        @stage = :checking
        super.tap { @stage = :sent }
      end

      def connect(...)
        @stage = :connecting if @stage == :checking
        super
      end
  end

  def initialize(keep_alive_timeout: 30, max_idle: 150)
    @keep_alive_timeout = keep_alive_timeout
    @max_idle = max_idle
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
      begin
        return send_over(idle, request, reused: true).tap { checkin(address, idle) }
      rescue StaleConnection
        # The push service had closed it: a new connection takes the push
      end
    end

    http.extend Stages
    http.keep_alive_timeout = @keep_alive_timeout
    http.start
    send_over(http, request, reused: false).tap { checkin(address, http) }
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
    def send_over(http, request, reused:)
      http.request(request)
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError => error
      close(http)
      # Only a connection that was idle can have been dead already: on a new one the error is the push service's
      raise StaleConnection if reused && http.stage == :checking
      # The push service may have it: don't send it twice, and don't report a dropped connection as a TLS failure
      raise ConnectionLost, "#{error.class}: #{error.message}" if http.stage == :sent
      raise
    end

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
        if @shut_down || @idle.values.sum(&:size) >= @max_idle
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
