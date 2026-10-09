require "web-push"
require "web_push/connections"
require "web_push/pool"
require "web_push/notification"

Rails.application.configure do
  config.x.web_push_pool = WebPush::Pool.new(
    invalid_subscription_handler: ->(subscription_id) do
      Rails.application.executor.wrap do
        Rails.logger.info "Destroying push subscription: #{subscription_id}"
        Push::Subscription.find_by(id: subscription_id)&.destroy
      end
    end
  )

  at_exit { config.x.web_push_pool.shutdown }
end

module WebPush::PersistentRequest
  def perform
    # Pin the connection to the public IP resolved (and guarded) by
    # Push::Subscription so delivery can't be rebound to a private address
    # between resolution and connect. There is no unpinned path: a delivery
    # without a resolved IP is not sent.
    endpoint_ip = @options[:endpoint_ip] or raise ArgumentError, "Push deliveries must be pinned to a resolved endpoint IP"

    # The explicit nil proxy address disables proxy discovery from
    # http_proxy/https_proxy. An egress proxy would open the TCP connection
    # itself and re-resolve the endpoint host, so http.ipaddr would no longer
    # pin the destination and the DNS-rebinding guarantee would be lost.
    # Push delivery to public vendor endpoints goes direct.
    http = (@options[:connection] ? WebPush::Connections::HTTP : Net::HTTP).new(uri.host, uri.port, nil)
    http.ipaddr = endpoint_ip
    http.use_ssl = true
    http.ssl_timeout = @options[:ssl_timeout] unless @options[:ssl_timeout].nil?
    http.open_timeout = @options[:open_timeout] unless @options[:open_timeout].nil?
    http.read_timeout = @options[:read_timeout] unless @options[:read_timeout].nil?

    req = Net::HTTP::Post.new(uri.request_uri, headers)
    req.body = body

    # WebPush::Connections reuses an open connection only for this same host
    # and pinned IP, so the guarantee holds for every request it sends.
    resp = @options[:connection] ? @options[:connection].request(http, req) : http.request(req)
    verify_response(resp)

    resp
  end
end

WebPush::Request.prepend WebPush::PersistentRequest
