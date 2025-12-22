module User::Resettable
  extend ActiveSupport::Concern

  RESET_PASSWORD_LINK_EXPIRY_DURATION = 5.hours

  class_methods do
    def find_by_password_reset_id(id)
      find_signed(id, purpose: :password_reset)
    end
  end

  def password_reset_id
    signed_id(purpose: :password_reset, expires_in: RESET_PASSWORD_LINK_EXPIRY_DURATION)
  end
end
