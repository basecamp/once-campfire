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

          user = find_or_claim_user!(sub:, email:)
          user.email_address = email
          user.name = name
          user.sso_provider = "backlit"
          user.sso_uid = sub
          # Backlit never manages Campfire administrator. New users are members;
          # roles granted in Campfire stay untouched.
          user.role = :member if user.new_record?
          user.status = :active if user.new_record? || user.deactivated?
          user.save!
          user
        end

        # Prefer the Backlit sub. If that is new but the email already exists (pre-cutover
        # local account), claim that row instead of inserting a duplicate.
        def find_or_claim_user!(sub:, email:)
          user = User.find_by(sso_provider: "backlit", sso_uid: sub)
          return user if user

          by_email = User.where("LOWER(email_address) = ?", email).first
          if by_email
            if by_email.sso? && !(by_email.sso_provider == "backlit" && by_email.sso_uid == sub)
              raise ActiveRecord::RecordNotUnique, "Email #{email} is linked to another SSO identity"
            end
            return by_email
          end

          User.new
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
