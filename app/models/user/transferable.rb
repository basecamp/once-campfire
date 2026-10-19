module User::Transferable
  extend ActiveSupport::Concern

  TRANSFER_LINK_EXPIRY_DURATION = 4.hours

  included do
    # Bound to the password, so changing it also ends sign-in links made before.
    generates_token_for :transfer, expires_in: TRANSFER_LINK_EXPIRY_DURATION do
      password_salt&.last(10)
    end
  end

  class_methods do
    def find_by_transfer_id(id)
      find_by_token_for(:transfer, id)
    end
  end

  def transfer_id
    generate_token_for(:transfer)
  end
end
