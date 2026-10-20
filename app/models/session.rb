class Session < ApplicationRecord
  ACTIVITY_REFRESH_RATE = 1.hour

  has_secure_token

  belongs_to :user

  before_create { self.last_active_at ||= Time.now }

  validate :user_password_unchanged, on: :create

  def resume(user_agent:, ip_address:)
    if last_active_at.before?(ACTIVITY_REFRESH_RATE.ago)
      update! user_agent: user_agent, ip_address: ip_address, last_active_at: Time.now
    end
  end

  private
    # A password change ends every session, so one can't start on a password checked before the change. Validated in
    # the save's transaction, which holds the database's write lock from the start, so a change commits either before
    # this check, and fails it, or after the insert, and ends this session with the others. Compared here rather than in
    # the query, which logs its values.
    def user_password_unchanged
      unless User.where(id: user_id).pick(:password_digest) == user.password_digest
        errors.add :user, :invalid
      end
    end
end
