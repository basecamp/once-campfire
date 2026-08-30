module ActiveStorageAuthentication
  extend ActiveSupport::Concern
  include Authentication::SessionLookup

  private
    def require_active_storage_authentication
      head :unauthorized unless find_session_by_cookie
    end
end
