require "concurrent"

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    POLICY_UNAVAILABLE_REASON = Oidc::POLICY_UNAVAILABLE_MESSAGE
    MAXIMUM_SUBSCRIPTIONS_PER_CONNECTION = Integer(
      ENV.fetch("ACTION_CABLE_MAXIMUM_SUBSCRIPTIONS_PER_CONNECTION", 100).to_s, 10
    )
    # Cable carries only subscription and presence/typing commands, not message uploads. Rails does
    # not expose websocket-driver's transport max_length, so this applies after frame aggregation.
    MAXIMUM_COMMAND_BYTES = 64.kilobytes
    unless MAXIMUM_SUBSCRIPTIONS_PER_CONNECTION.between?(1, 1_000)
      raise ArgumentError,
        "ACTION_CABLE_MAXIMUM_SUBSCRIPTIONS_PER_CONNECTION must be between 1 and 1000"
    end

    include Authentication::SessionLookup

    before_command :verify_current_session

    identified_by :current_user, :current_session_id
    attr_accessor :current_session, :current_authorization_generation

    class << self
      def disconnect_session(user:, session_id:, reason:, reconnect:)
        remote = ActionCable.server.remote_connections.where(
          current_user: user, current_session_id: session_id
        )
        ActionCable.server.broadcast remote.send(:internal_channel), {
          type: "disconnect", reason:, reconnect:
        }
      end

      def disconnect_user(user:, reason:, reconnect:)
        ActionCable.server.broadcast user_internal_channel(user), {
          type: "disconnect", reason:, reconnect:
        }
      end

      def user_internal_channel(user)
        "action_cable/user/#{user.to_gid_param}"
      end
    end

    def initialize(...)
      super
      @subscriptions = ApplicationCable::Subscriptions.new(self)
    end

    def connect
      if Oidc.required? && !Oidc::Activation.ready?
        reject_unauthorized_connection
      end

      self.current_session = find_verified_session
      self.current_user = current_session.user
      self.current_session_id = current_session.id
      self.current_authorization_generation = current_user.authorization_generation
      monitor_session_expiration
    rescue Oidc::PolicyUnavailable, ActiveRecord::ActiveRecordError
      reject_unauthorized_connection
    end

    def disconnect
      @session_expiration_monitor&.cancel
    end

    def on_message(websocket_message)
      if websocket_message.is_a?(String) && websocket_message.bytesize > MAXIMUM_COMMAND_BYTES
        close reason: "Command too large", reconnect: false
      else
        super
      end
    end

    def transmit(cable_message)
      if application_message?(cable_message) && current_session_id && !@closing_invalid_session
        case current_session_status
        when :valid
          transmissions_for(cable_message).each { super(_1) }
        when :unavailable
          close_policy_unavailable
        else
          close_invalid_session
        end
      else
        transmissions_for(cable_message).each { super(_1) }
      end
    end

    private
      def find_verified_session
        if verified_session = find_session_by_cookie
          verified_session
        else
          reject_unauthorized_connection
        end
      end

      def monitor_session_expiration
        return unless current_session.expires_at

        interval = [ current_session.expires_at - Time.current, 1.second ].max
        @session_expiration_monitor = Concurrent::ScheduledTask.execute(interval) { send_async :expire_session }
      end

      def expire_session
        @session_expiration_monitor&.cancel
        Session.find_by(id: current_session_id)&.revoke!
      ensure
        close reason: "Session expired", reconnect: false
      end

      def verify_current_session
        case current_session_status
        when :valid
          return
        when :unavailable
          close_policy_unavailable
        else
          close_invalid_session
        end

        throw :abort
      end

      def current_session_status
        current_session_valid? ? :valid : :revoked
      rescue Oidc::PolicyUnavailable, ActiveRecord::ActiveRecordError
        :unavailable
      end

      def current_session_valid?
        return false if Oidc.required? && !Oidc::Activation.ready?

        session = Session.includes(:identity, :user).find_by(id: current_session_id)
        session&.valid_for_authentication? &&
          session.user.authorization_generation == current_authorization_generation || false
      end

      def process_internal_message(message)
        if message["type"] == "disconnect" && message["reason"] == Session::REVOKED_REASON
          close reason: message["reason"], reconnect: message.fetch("reconnect", true)
        else
          super
        end
      end

      def subscribe_to_internal_channel
        super

        # Every authenticated socket also needs a user scope independent of its session identifier.
        channel = self.class.user_internal_channel(current_user)
        callback = ->(message) { process_internal_message decode(message) }
        @_internal_subscriptions << [ channel, callback ]
        server.event_loop.post { pubsub.subscribe(channel, callback) }
      end

      def application_message?(cable_message)
        type = cable_message[:type] || cable_message["type"] if cable_message.respond_to?(:[])
        !type.in?(ActionCable::INTERNAL[:message_types].values)
      end

      def transmissions_for(cable_message)
        return [ cable_message ] unless cable_message.respond_to?(:key?)

        identifier_key = cable_message.key?(:identifier) ? :identifier : "identifier"
        identifier = cable_message[identifier_key]
        return [ cable_message ] unless identifier

        if subscription_confirmation?(cable_message) &&
            subscriptions.respond_to?(:confirmation_identifiers_for)
          identifiers = subscriptions.confirmation_identifiers_for(identifier)
          return identifiers.map { cable_message.merge(identifier_key => _1) } if identifiers
        end

        return [ cable_message ] unless cable_message.key?(:message) || cable_message.key?("message")
        return [ cable_message ] unless subscriptions.respond_to?(:delivery_identifiers_for)

        subscriptions.delivery_identifiers_for(identifier).map do |delivery_identifier|
          cable_message.merge(identifier_key => delivery_identifier)
        end
      end

      def subscription_confirmation?(cable_message)
        type = cable_message[:type] || cable_message["type"]
        type == ActionCable::INTERNAL[:message_types][:confirmation]
      end

      def close_invalid_session
        @closing_invalid_session = true
        @session_expiration_monitor&.cancel
        close reason: Session::REVOKED_REASON, reconnect: false
      end

      def close_policy_unavailable
        @closing_invalid_session = true
        @session_expiration_monitor&.cancel
        close reason: POLICY_UNAVAILABLE_REASON, reconnect: true
      end
  end
end
