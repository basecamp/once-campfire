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

  def update_with_staged_avatar!(attributes, actor:, current_password: nil, current_session: nil)
    attributes = attributes.to_h.symbolize_keys
    upload = attributes.delete(:avatar)
    current_session_id = current_session&.id
    current_session_token = current_session&.token&.dup

    StagedUpload.with(upload) do |blob|
      User::MutationFence.with([ actor.id, id ]) do
        authenticated_session = if current_session
          Session.authenticate_exact!(
            id: current_session_id, token: current_session_token, user_id: actor.id
          )
        end
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
          rotate_password_credentials!(user, authenticated_session) if password_change
          StagedUpload.attach! user.avatar, blob if blob
        end
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

  private
    def rotate_password_credentials!(user, current_session)
      retained_session = user.sessions.lock.find_by(id: current_session&.id)
      unless retained_session
        raise User::AuthorizationError, "the authenticated session cannot be rotated"
      end

      CredentialIntent.where(user_id: user.id).delete_all
      Session.revoke_all! user.sessions.where.not(id: retained_session.id)
      user.increment! :authorization_generation
      retained_session.regenerate_token
    end
end
