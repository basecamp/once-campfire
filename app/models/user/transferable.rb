module User::Transferable
  extend ActiveSupport::Concern

  TRANSFER_LINK_EXPIRY_DURATION = 4.hours

  def transfer_id
    CredentialIntent.issue_transfer_grant!(self, expires_in: TRANSFER_LINK_EXPIRY_DURATION)
  end
end
