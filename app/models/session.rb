class Session < ApplicationRecord
  ACTIVITY_REFRESH_RATE = 1.hour

  has_secure_token
  encrypts :oidc_id_token

  belongs_to :user

  before_create { self.last_active_at ||= Time.now }

  def self.start!(user_agent:, ip_address:, sso_provider: nil, oidc_id_token: nil)
    create!(
      user_agent: user_agent,
      ip_address: ip_address,
      sso_provider: sso_provider,
      oidc_id_token: oidc_id_token
    )
  end

  def resume(user_agent:, ip_address:)
    if last_active_at.before?(ACTIVITY_REFRESH_RATE.ago)
      update! user_agent: user_agent, ip_address: ip_address, last_active_at: Time.now
    end
  end
end
