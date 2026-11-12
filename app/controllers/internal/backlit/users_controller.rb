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
          name = campfire_name_from(params[:name], email)

          user = find_or_claim_user!(sub:, email:)
          user.email_address = email
          user.name = name
          user.sso_provider = "backlit"
          user.sso_uid = sub
          # Claiming a local or join-code account for Backlit must drop the old
          # password so email/password sign-in cannot keep working.
          user.password_digest = nil if user.password_digest.present?
          apply_backlit_admin_role!(user)
          user.status = :active if user.new_record? || user.deactivated?
          user.save!
          user
        end

        # Backlit is the source of truth for Campfire administrator when `admin`
        # is present. Bots stay bots. Omitting `admin` preserves the current role
        # for older clients (new users still default to member).
        def apply_backlit_admin_role!(user)
          return if user.bot?

          if params.key?(:admin)
            user.role = ActiveModel::Type::Boolean.new.cast(params[:admin]) ? :administrator : :member
          elsif user.new_record?
            user.role = :member
          end
        end

        # Prefer Backlit login Name. Never store a full email in Campfire's name.
        def campfire_name_from(raw_name, email)
          name = raw_name.to_s.strip.presence
          return email.split("@").first if name.blank?
          return email.split("@").first if name.include?("@")

          name
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
