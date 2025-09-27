class ApplicationController < ActionController::Base
  include AllowBrowser, Authentication, Authorization, SetCurrentRequest, SetPlatform, TrackedRoomVisit, VersionHeaders
  include Turbo::Streams::Broadcasts, Turbo::Streams::StreamName

  before_action :forbid_banned_user

  private
    def forbid_banned_user
      return unless Current.user&.banned?
      return if banned_user_allowed_action?

      # GG: flash seems is unable to be shown, so we do not put it
      # flash.now[:alert] = "Your account has been banned."

      if turbo_request?
        render turbo_stream: turbo_stream.update("main-content", partial: "application/banned_notice"), status: :forbidden
      elsif request.format.html?
        render "application/banned", status: :forbidden
      else
        head :forbidden
      end
    end

    def banned_user_allowed_action?
      controller_path == "sessions" || controller_path.start_with?("sessions/")
    end

    def turbo_request?
      turbo_frame_request? || request.format == Mime[:turbo_stream]
    end
end
