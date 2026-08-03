module User::Avatar
  extend ActiveSupport::Concern

  class PasswordVerificationFailed < StandardError; end

  included do
    has_one_attached :avatar do |attachable|
      attachable.variant :square, resize_to_limit: [ 512, 512 ], format: :webp
    end
  end

  class_methods do
    def from_avatar_token(sid)
      find_signed!(sid, purpose: :avatar)
    end
  end

  def avatar_token
    signed_id(purpose: :avatar)
  end

  def avatar_variant
    avatar.variant(:square).processed if avatar.variable?
  end

  def update_with_staged_avatar!(attributes, actor:, current_password: nil)
    attributes = attributes.to_h.symbolize_keys
    upload = attributes.delete(:avatar)

    StagedUpload.with(upload) do |blob|
      transaction do
        user = self.class.lock_active! actor
        raise User::AuthorizationError, "user cannot update this profile" unless user.id == id
        password_change = attributes[:password].present?
        password_account_email_change = attributes.key?(:email_address) &&
          self.class.normalize_email_address(attributes[:email_address]) != user.email_address &&
          !user.identities.exists?(issuer: Oidc.issuer)
        if password_change || password_account_email_change
          password_change_allowed = !password_change || Oidc.local_authentication_allowed_for?(user)
          unless password_change_allowed && user.authenticate_password(current_password.to_s)
            raise PasswordVerificationFailed, "current password is incorrect"
          end
        end

        user.update!(attributes)
        StagedUpload.attach! user.avatar, blob if blob
      end
    end
    reload
  end

  def remove_avatar!(actor:)
    transaction do
      user = self.class.lock_active! actor
      raise User::AuthorizationError, "user cannot update this profile" unless user.id == id

      user.avatar.attachment&.destroy!
    end
    reload
  end
end
