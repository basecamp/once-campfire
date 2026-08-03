require "web-push"
require "restricted_http/response_header_guard"
require "web_push/endpoint"
require "web_push/pool"
require "web_push/notification"

Rails.application.configure do
  config.x.web_push_pool = WebPush::Pool.new(
    invalid_subscription_handler: ->(subscription_id) do
      Rails.logger.info "Destroying expired push subscription: #{subscription_id}"
      Push::Subscription.find_by(id: subscription_id)&.destroy!
    end
  )

  at_exit { config.x.web_push_pool.shutdown }
end

module WebPush::GuardedRequest
  MAXIMUM_REQUEST_TIME = 10.seconds
  MAXIMUM_RESPONSE_SIZE = 64.kilobytes
  IO_TIMEOUT = 5.seconds

  def perform
    endpoint, address = WebPush::Endpoint.resolve(@endpoint)
    http = Net::HTTP.new(endpoint.hostname, endpoint.port, nil)
    http.ipaddr = address
    http.use_ssl = true
    http.open_timeout = IO_TIMEOUT
    http.read_timeout = IO_TIMEOUT
    http.write_timeout = IO_TIMEOUT

    req = Net::HTTP::Post.new(endpoint.request_uri, headers)
    req.body = body

    response = Timeout.timeout(MAXIMUM_REQUEST_TIME) do
      RestrictedHTTP::ResponseHeaderGuard.with_limits do
        http.request(req) do |incoming|
          body = +"".b
          incoming.read_body do |chunk|
            if body.bytesize + chunk.bytesize > MAXIMUM_RESPONSE_SIZE
              raise WebPush::Endpoint::Denied, "Web Push response exceeded the size limit"
            end
            body << chunk
          end
          incoming.instance_variable_set :@body, body
        end
      end
    end
    verify_response(response)

    response
  rescue RestrictedHTTP::ResponseHeaderGuard::Exceeded => error
    raise WebPush::Endpoint::Denied.new("Web Push response headers exceeded safety limits"), cause: error
  rescue Timeout::Error
    raise WebPush::Endpoint::Unavailable, "Web Push request exceeded #{MAXIMUM_REQUEST_TIME.to_i} seconds"
  end
end

WebPush::Request.prepend WebPush::GuardedRequest
