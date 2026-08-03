require "net/http"
require "ipaddr"
require "resolv"
require "restricted_http/private_network_guard"
require "restricted_http/response_header_guard"
require "timeout"
require "uri"

class Webhook < ApplicationRecord
  class DeliveryError < StandardError; end
  class RetryableDeliveryError < DeliveryError; end

  class Endpoint
    class Denied < StandardError; end

    MAXIMUM_URL_BYTES = 2_048
    RESOLUTION_TIMEOUT = 3.seconds

    class << self
      def parse(value)
        string = value.to_s
        raise Denied, "Webhook URL is too long" if string.bytesize > MAXIMUM_URL_BYTES

        URI.parse(string).tap do |uri|
          unless uri.is_a?(URI::HTTPS) && uri.hostname.present? && uri.port == 443 &&
              uri.userinfo.nil? && uri.fragment.nil?
            raise Denied, "Webhook URL must be public HTTPS on port 443"
          end
          if ip_address?(uri.hostname) && RestrictedHTTP::PrivateNetworkGuard.private_ip?(uri.hostname)
            raise Denied, "Webhook URL must not use a private or special-use address"
          end
        end
      rescue URI::InvalidURIError
        raise Denied, "Webhook URL is invalid"
      end

      def resolve(value, deadline:)
        uri = parse(value)
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise RetryableDeliveryError, "Webhook endpoint resolution timed out" unless remaining.positive?

        addresses = Timeout.timeout([ RESOLUTION_TIMEOUT, remaining ].min, RetryableDeliveryError) do
          Resolv.getaddresses(uri.hostname)
        end
        if addresses.empty? || addresses.any? { RestrictedHTTP::PrivateNetworkGuard.private_ip?(_1) }
          raise Denied, "Webhook endpoint resolved to a private or invalid address"
        end

        [ uri, addresses.first ]
      rescue Resolv::ResolvError, SocketError => error
        raise RetryableDeliveryError.new("Webhook endpoint could not be resolved"), cause: error
      end

      private
        def ip_address?(host)
          IPAddr.new(host)
          true
        rescue IPAddr::InvalidAddressError
          false
        end
    end
  end

  DELIVERY_TIMEOUT = 7.seconds
  MAXIMUM_RESPONSE_HEADER_BYTES = RestrictedHTTP::ResponseHeaderGuard::MAXIMUM_TOTAL_BYTES
  IDEMPOTENCY_HEADER = "Idempotency-Key"
  UUID_PATTERN = /\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/

  belongs_to :user

  before_validation :rotate_delivery_generation, if: -> { new_record? || will_save_change_to_url? }

  validates :url, presence: true, length: { maximum: Endpoint::MAXIMUM_URL_BYTES }
  validates :delivery_generation, presence: true, uniqueness: true, format: { with: UUID_PATTERN }
  validate :endpoint_is_safe

  def deliver(message, delivery_id:)
    User::MutationFence.with(user_id) do
      current = self.class.find_by(id:, user_id:, delivery_generation:)
      raise DeliveryError, "Webhook target changed before delivery" unless current

      current.send :deliver_without_fence, message, delivery_id:
    end
  end

  def update(attributes)
    with_target_mutation_fence(attributes) { super }
  end

  def update!(attributes)
    with_target_mutation_fence(attributes) { super }
  end

  def save(...)
    with_pending_target_mutation_fence { super }
  end

  def save!(...)
    with_pending_target_mutation_fence { super }
  end

  def destroy
    User::MutationFence.with(user_id) { super }
  end

  def destroy!
    User::MutationFence.with(user_id) { super }
  end

  private
    def deliver_without_fence(message, delivery_id:)
      post(payload(message), delivery_id:).tap do |response|
        raise DeliveryError, "Webhook returned HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        if text = extract_text_from(response)
          receive_text_reply_to(message.room, text:, delivery_id:)
        elsif attachment = extract_attachment_from(response)
          receive_attachment_reply_to(message.room, attachment:, delivery_id:)
        end
      end
    end

    def post(payload, delivery_id:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + DELIVERY_TIMEOUT
      endpoint, address = Endpoint.resolve(url, deadline:)
      headers = { "Content-Type" => "application/json" }
      headers[IDEMPOTENCY_HEADER] = delivery_id
      request = Net::HTTP::Post.new(endpoint, headers).tap { |post| post.body = payload }

      Timeout.timeout(remaining_time(deadline), RetryableDeliveryError) do
        RestrictedHTTP::ResponseHeaderGuard.with_limits do
          http(endpoint, address, deadline:).request(request) do |response|
            verify_response_headers! response
            response.body = ContentLimits.read(
              response, maximum: ContentLimits::WEBHOOK_RESPONSE_BYTES, description: "webhook response"
            )
            response
          end
        end
      end
    rescue RestrictedHTTP::ResponseHeaderGuard::Exceeded => error
      raise DeliveryError.new("Webhook response headers exceeded safety limits"), cause: error
    rescue Endpoint::Denied, ContentLimits::Exceeded
      raise
    rescue RetryableDeliveryError
      raise
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, Timeout::Error,
        SocketError, SystemCallError, EOFError, IOError, OpenSSL::OpenSSLError => error
      raise RetryableDeliveryError.new("Webhook request failed: #{error.class.name}"), cause: error
    end

    def http(endpoint, address, deadline:)
      Net::HTTP.new(endpoint.hostname, endpoint.port, nil).tap do |http|
        http.ipaddr = address
        http.use_ssl = true
        http.max_retries = 0
        http.open_timeout = remaining_time(deadline)
        http.read_timeout = remaining_time(deadline)
        http.write_timeout = remaining_time(deadline)
      end
    end

    def remaining_time(deadline)
      (deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)).tap do |remaining|
        raise RetryableDeliveryError, "Webhook request exceeded #{DELIVERY_TIMEOUT.to_i} seconds" unless remaining.positive?
      end
    end

    def verify_response_headers!(response)
      bytes = response.each_header.sum { |name, value| name.bytesize + value.bytesize + 4 }
      if bytes > MAXIMUM_RESPONSE_HEADER_BYTES
        raise DeliveryError, "Webhook response headers exceeded #{MAXIMUM_RESPONSE_HEADER_BYTES} bytes"
      end

      if response["Content-Length"]
        length = Integer(response["Content-Length"], 10)
        ContentLimits.verify! length,
          maximum: ContentLimits::WEBHOOK_RESPONSE_BYTES, description: "webhook response"
      end
    rescue ArgumentError
      raise DeliveryError, "Webhook returned an invalid Content-Length"
    end

    def payload(message)
      {
        user:    { id: message.creator.id, name: message.creator.name },
        room:    {
          id: message.room.id, name: message.room.name, path: room_bot_messages_path(message),
          authorization: "Bearer #{user.bot_key}"
        },
        message: { id: message.id, body: { html: message.body.body, plain: without_recipient_mentions(message.plain_text_body) }, path: message_path(message) }
      }.to_json
    end

    def message_path(message)
      Rails.application.routes.url_helpers.room_at_message_path(message.room, message)
    end

    def room_bot_messages_path(message)
      Rails.application.routes.url_helpers.room_bot_messages_path(message.room)
    end

    def extract_text_from(response)
      String.new(response.body).force_encoding("UTF-8") if response.code == "200" && response.content_type.in?(%w[ text/html text/plain ])
    end

    def receive_text_reply_to(room, text:, delivery_id:)
      ContentLimits.verify! text.bytesize,
        maximum: ContentLimits::MESSAGE_BODY_BYTES, description: "message body"
      room.messages.create_with_attachment!(
        body: text, creator: user, client_message_id: reply_client_message_id(delivery_id)
      )
    end

    def extract_attachment_from(response)
      if response.content_type && mime_type = Mime::Type.lookup(response.content_type)
        {
          io: StringIO.new(response.body), filename: "attachment.#{mime_type.symbol}", content_type: mime_type.to_s
        }
      end
    end

    def receive_attachment_reply_to(room, attachment:, delivery_id:)
      room.messages.create_with_attachment!(
        attachment:, creator: user, client_message_id: reply_client_message_id(delivery_id)
      )
    end

    def reply_client_message_id(delivery_id)
      "webhook-reply-#{delivery_id}"
    end

    def without_recipient_mentions(body)
      body \
        .gsub(user.attachable_plain_text_representation(nil), "") # Remove mentions of the recipient user
        .gsub(/\A\p{Space}+|\p{Space}+\z/, "") # Remove leading and trailing whitespace uncluding unicode spaces
    end


    def endpoint_is_safe
      Endpoint.parse url
    rescue Endpoint::Denied => error
      errors.add :url, error.message
    end

    def rotate_delivery_generation
      self.delivery_generation = SecureRandom.uuid
    end

    def with_target_mutation_fence(attributes)
      if persisted? && attributes.to_h.stringify_keys.key?("url")
        User::MutationFence.with(user_id) { yield }
      else
        yield
      end
    end

    def with_pending_target_mutation_fence
      if persisted? && will_save_change_to_url?
        User::MutationFence.with(user_id) { yield }
      else
        yield
      end
    end
end
