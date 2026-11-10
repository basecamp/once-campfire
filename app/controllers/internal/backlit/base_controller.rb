module Internal
  module Backlit
    class BaseController < ActionController::API
      before_action :authenticate_provisioning_token!

      private
        def authenticate_provisioning_token!
          expected = ENV["BACKLIT_PROVISIONING_TOKEN"].to_s
          provided = request.headers["Authorization"].to_s.delete_prefix("Bearer ").strip

          if expected.blank? || !ActiveSupport::SecurityUtils.secure_compare(expected, provided)
            head :unauthorized
          end
        end

        def find_user_by_sub!(sub)
          User.find_by!(sso_provider: "backlit", sso_uid: sub.to_s)
        end
    end
  end
end
