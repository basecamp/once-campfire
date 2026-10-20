module ApplicationCable
  class Connection < ActionCable::Connection::Base
    include Authentication::SessionLookup

    SESSION_CHECK_INTERVAL = 1.minute

    identified_by :current_user

    def connect
      self.current_user = find_verified_user
      @session_checked_at = Time.now
    end

    # Signing out or changing the password ends sessions and then disconnects their connections, but a connection can
    # miss that: one that found its session just before isn't listening yet. So on the server's heartbeat, which
    # reaches every open connection, each one looks its session up again now and then, and closes once it's gone.
    def beat
      super
      check_session if @session_checked_at.before?(SESSION_CHECK_INTERVAL.ago)
    end

    private
      def find_verified_user
        if @verified_session = find_session_by_cookie
          @verified_session.user
        else
          reject_unauthorized_connection
        end
      end

      def check_session
        @session_checked_at = Time.now
        perform_work -> { close_unless_session_remains }, :call
      end

      def close_unless_session_remains
        unless Session.exists?(@verified_session.id)
          close reason: ActionCable::INTERNAL[:disconnect_reasons][:unauthorized]
        end
      end
  end
end
