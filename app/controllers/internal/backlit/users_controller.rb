module Internal
  module Backlit
    class UsersController < BaseController
      def create
        user = upsert_user!
        render json: user_payload(user), status: :created
      end

      def update
        user = upsert_user!
        render json: user_payload(user)
      end

      private
        def upsert_user!
          sub = params.require(:sub).to_s
          email = params.require(:email).to_s.downcase.strip
          name = params[:name].presence || email.split("@").first
          admin = ActiveModel::Type::Boolean.new.cast(params[:admin])

          user = User.find_or_initialize_by(sso_provider: "backlit", sso_uid: sub)
          user.email_address = email
          user.name = name
          user.role = admin ? :administrator : :member
          user.status = :active if user.new_record? || user.deactivated?
          user.save!
          user
        end

        def user_payload(user)
          {
            id: user.id,
            sub: user.sso_uid,
            email: user.email_address,
            name: user.name,
            role: user.role
          }
        end
    end
  end
end
