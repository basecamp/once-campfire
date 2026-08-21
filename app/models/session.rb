class Session < ApplicationRecord
  ACTIVITY_REFRESH_RATE = 1.hour
  REVOKED_REASON = "Session revoked"

  has_secure_token

  belongs_to :user
  belongs_to :identity, optional: true
  has_many :push_subscriptions, class_name: "Push::Subscription", dependent: :delete_all

  validates :authentication_method, inclusion: { in: %w[ legacy password oidc transfer ] }
  validates :oidc_session_id, length: { in: 1..Identity::MAXIMUM_IDENTIFIER_LENGTH }, allow_nil: true
  validates :oidc_issued_at, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validates :oidc_session_generation, numericality: { only_integer: true, greater_than: 0 }, allow_nil: true
  validate :identity_belongs_to_user, :identity_matches_authentication_method,
    :authentication_method_allowed_by_policy, :user_is_active, :identity_is_active,
    :oidc_session_id_is_bounded

  before_create { self.last_active_at ||= Time.now }
  before_validation :set_oidc_configuration_fingerprint, :set_expiration, on: :create
  after_destroy_commit :disconnect_revoked_session

  scope :unexpired, -> { where(expires_at: nil).or(where(expires_at: Time.current..)) }

  def self.authenticatable
    current_oidc_generation = Oidc::SessionGeneration.current!
    return none if Oidc.rollback_prepared?

    relation = unexpired.joins(:user).merge(User.active)
    federated = relation.where(
      authentication_method: "oidc",
      oidc_configuration_fingerprint: Oidc.configuration.fingerprint,
      oidc_session_generation: current_oidc_generation,
      identity_id: Identity.where(
        issuer: Oidc.issuer, provider_fingerprint: Oidc.provider_fingerprint,
        provider_revoked_at: nil
      ).select(:id)
    ) if Oidc.enabled?

    unless Oidc.required_active?
      local = relation.where.not(authentication_method: "oidc").where(identity_id: nil)
      local = local.where.not(authentication_method: "transfer") if Oidc.enabled?
      return Oidc.enabled? ? local.or(federated) : local
    end

    recovery = relation.where(user: Oidc.break_glass_user, authentication_method: "password").where.not(expires_at: nil)
    federated.or(recovery)
  rescue Oidc::PolicyUnavailable
    none
  end

  def self.start!(user:, user_agent:, ip_address:, identity: nil, authentication_method: nil,
      oidc_session_id: nil, oidc_issued_at: nil)
    prune_expired! unless connection.transaction_open?
    Oidc::SessionGeneration.with_current do |generation|
      transaction do
        user = User.lock_active! user
        authentication_method ||= identity ? "oidc" : "password"
        if authentication_method == "oidc" && identity
          Oidc::Revocation.prune_expired!
          Oidc::Revocation.guard_session!(
            issuer: identity.issuer, subject: identity.subject, sid: oidc_session_id,
            issued_at: oidc_issued_at
          )
        end
        create! user:, user_agent:, ip_address:, identity:, authentication_method:, oidc_session_id:,
          oidc_issued_at:, oidc_session_generation: (generation if authentication_method == "oidc")
      end
    end
  end

  def self.authenticate_exact!(id:, token:, user_id:)
    session = includes(:identity, :user).find_by(id:, token:, user_id:)
    unless session&.valid_for_authentication?
      raise User::AuthorizationError, "authenticated session was revoked"
    end

    session
  end

  def self.revoke_all!(relation = all, limit: nil)
    scope = relation.reorder(arel_table[:id])
    scope = scope.limit(limit) if limit
    rows = scope.pluck(arel_table[:id], arel_table[:user_id])
    return 0 if rows.empty?

    destroyed = 0
    User::MutationFence.with(rows.map(&:last)) do
      transaction do
        where(id: rows.map(&:first)).order(:id).each do |session|
          session.destroy!
          destroyed += 1
        end
      end
    end
    destroyed
  end

  def self.revoke_all_in_batches!(relation = all, batch_size: 100)
    total = 0
    loop do
      count = revoke_all!(relation, limit: batch_size)
      total += count
      return total if count.zero?
    end
  end

  def self.prune_expired!(limit: 100)
    ids = where(expires_at: ...Time.current).order(:expires_at, :id).limit(limit).ids
    revoke_all! where(id: ids)
  end

  def revoke!
    self.class.revoke_all! self.class.where(id:)
    self
  end

  def resume(user_agent:, ip_address:)
    if last_active_at.before?(ACTIVITY_REFRESH_RATE.ago)
      update! user_agent: user_agent, ip_address: ip_address, last_active_at: Time.now
    end
  end

  def valid_for_authentication?
    current_oidc_generation = Oidc::SessionGeneration.current!
    return false if Oidc.rollback_prepared?
    return false unless authentication_method.in?(%w[ legacy password oidc transfer ])
    return false unless user.active?
    return false if expires_at&.past?
    return false unless valid_identity_binding?
    return false if authentication_method == "transfer" && Oidc.enabled?
    if authentication_method == "oidc"
      return Oidc.current_identity?(identity) && !identity.provider_revoked_at? &&
        oidc_configuration_fingerprint == Oidc.configuration.fingerprint &&
        oidc_session_generation == current_oidc_generation
    end
    return true unless Oidc.required_active?

    authentication_method == "password" && expires_at.present? && Oidc.break_glass?(user)
  end

  def disconnect_remote_connections(reconnect: false, reason: nil)
    if reason
      ApplicationCable::Connection.disconnect_session(
        user:, session_id: id, reason:, reconnect:
      )
    else
      ActionCable.server.remote_connections.where(
        current_user: user, current_session_id: id
      ).disconnect reconnect:
    end
  rescue StandardError => error
    Rails.logger.error "Failed to disconnect Action Cable session_id=#{id} error=#{error.class.name}"
  end

  private
    def identity_belongs_to_user
      errors.add :identity, "must belong to the session user" if identity && identity.user_id != user_id
    end

    def identity_matches_authentication_method
      invalid_oidc = authentication_method == "oidc" &&
        (!identity || oidc_configuration_fingerprint.blank? || oidc_session_generation.blank? ||
          oidc_issued_at.blank?)
      invalid_local = authentication_method != "oidc" &&
        (identity || oidc_configuration_fingerprint.present? || oidc_session_generation.present? ||
          oidc_session_id.present? || oidc_issued_at.present?)
      if invalid_oidc || invalid_local
        errors.add :identity, "must match the authentication method"
      end
    end

    def valid_identity_binding?
      if authentication_method == "oidc"
        identity && identity.user_id == user_id && expires_at.present? &&
          oidc_configuration_fingerprint.present? && oidc_session_generation.present? && oidc_issued_at.present?
      else
        identity.nil? && oidc_configuration_fingerprint.nil? && oidc_session_generation.nil? &&
          oidc_session_id.nil? && oidc_issued_at.nil?
      end
    end

    def oidc_session_id_is_bounded
      if oidc_session_id && oidc_session_id.bytesize > Identity::MAXIMUM_IDENTIFIER_LENGTH
        errors.add :oidc_session_id, "is too long"
      end
    end

    def user_is_active
      errors.add :user, "must be active" unless user&.active?
    end

    def identity_is_active
      errors.add :identity, "has been revoked by its provider" if identity&.provider_revoked_at?
    end

    def authentication_method_allowed_by_policy
      if authentication_method == "transfer" && Oidc.enabled?
        errors.add :authentication_method, "is disabled while single sign-on is enabled"
        return
      end

      if Oidc.rollback_prepared?
        errors.add :authentication_method, "is disabled while rollback is prepared"
        return
      end

      return unless Oidc.required_active?
      return if authentication_method == "oidc"
      return if authentication_method == "password" && expires_at.present? && Oidc.break_glass?(user)

      errors.add :authentication_method, "is disabled by required single sign-on"
    end

    def set_expiration
      if authentication_method == "oidc" || (authentication_method == "password" && Oidc.required? && Oidc.break_glass?(user))
        self.expires_at ||= Oidc.session_lifetime_seconds.seconds.from_now
      end
    end

    def set_oidc_configuration_fingerprint
      if authentication_method == "oidc" || identity
        self.oidc_configuration_fingerprint ||= Oidc.configuration.fingerprint
      end
    end

    def disconnect_revoked_session
      disconnect_remote_connections reason: REVOKED_REASON
    end
end
