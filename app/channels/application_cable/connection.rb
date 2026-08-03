require "concurrent"

module ApplicationCable
  class Connection < ActionCable::Connection::Base
    include Authentication::SessionLookup

    before_command :verify_current_session

    identified_by :current_user, :current_session_id
    attr_accessor :current_session, :current_authorization_generation

    def connect
      if Oidc.required? && !Oidc::Activation.ready?
        reject_unauthorized_connection
      end

      self.current_session = find_verified_session
      self.current_user = current_session.user
      self.current_session_id = current_session.id
      self.current_authorization_generation = current_user.authorization_generation
      monitor_session_expiration
    rescue Oidc::PolicyUnavailable
      reject_unauthorized_connection
    end

    def disconnect
      @session_expiration_monitor&.cancel
    end

    def transmit(cable_message)
      if application_message?(cable_message) && current_session_id && !@closing_invalid_session && !current_session_valid?
        close_invalid_session
      else
        super
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
        Session.find_by(id: current_session_id)&.destroy!
      ensure
        close reason: "Session expired", reconnect: false
      end

      def verify_current_session
        return if current_session_valid?

        close_invalid_session
        throw :abort
      end

      def current_session_valid?
        return false if Oidc.required? && !Oidc::Activation.ready?

        session = Session.includes(:identity, :user).find_by(id: current_session_id)
        session&.valid_for_authentication? &&
          session.user.authorization_generation == current_authorization_generation || false
      rescue Oidc::PolicyUnavailable, ActiveRecord::ActiveRecordError
        false
      end

      def application_message?(cable_message)
        type = cable_message[:type] || cable_message["type"] if cable_message.respond_to?(:[])
        !type.in?(ActionCable::INTERNAL[:message_types].values)
      end

      def close_invalid_session
        @closing_invalid_session = true
        @session_expiration_monitor&.cancel
        close reason: "Session revoked", reconnect: false
      end
  end
end
