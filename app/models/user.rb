class User < ApplicationRecord
  class AuthorizationError < StandardError; end

  include Avatar, Bannable, Bot, Mentionable, Role, Transferable

  has_many :memberships, dependent: :delete_all
  has_many :rooms, through: :memberships

  has_many :reachable_messages, through: :rooms, source: :messages
  has_many :messages, dependent: :destroy, foreign_key: :creator_id

  has_many :push_subscriptions, class_name: "Push::Subscription", dependent: :delete_all

  has_many :boosts, dependent: :destroy, foreign_key: :booster_id
  has_many :searches, dependent: :delete_all

  has_many :sessions, dependent: :destroy do
    def start!(user_agent:, ip_address:, identity: nil, authentication_method: nil, oidc_session_id: nil,
        oidc_issued_at: nil)
      Session.start!(
        user: proxy_association.owner, user_agent:, ip_address:, identity:, authentication_method:,
        oidc_session_id:, oidc_issued_at:
      )
    end
  end
  has_many :identities, dependent: :destroy
  has_many :bans, dependent: :destroy
  has_many :ban_cleanup_intents, dependent: :delete_all

  enum :status, %i[ active deactivated banned ], default: :active

  has_secure_password validations: false
  normalizes :email_address, with: ->(email_address) { EmailAddress.normalize(email_address) }

  before_save :normalize_email_identity
  after_create :grant_membership_to_open_rooms
  validate :preserve_required_recovery_binding, on: :update

  scope :ordered, -> { order("LOWER(name)") }
  scope :filtered_by, ->(query) { where("name like ?", "%#{query}%") }

  class << self
    def normalize_email_address(email_address)
      normalize_value_for :email_address, email_address
    end

    def lock_active!(user_or_id)
      id = user_or_id.respond_to?(:id) ? user_or_id.id : user_or_id
      where(id:).update_all("authorization_generation = authorization_generation")
      uncached { lock.find(id) }.tap do |user|
        raise AuthorizationError, "user is not active" unless user.active?
      end
    rescue ActiveRecord::RecordNotFound
      raise AuthorizationError, "user is not active"
    end

    def lock_administrator!(user_or_id)
      lock_active!(user_or_id).tap do |user|
        raise AuthorizationError, "user is not an administrator" unless user.administrator?
      end
    end

    def lock_room_member!(user_or_id, room_id)
      lock_active!(user_or_id).tap do |user|
        Membership.lock.find_by!(user_id: user.id, room_id:)
      end
    rescue ActiveRecord::RecordNotFound
      raise AuthorizationError, "user is not a room member"
    end

    def lock_room_administrator!(user_or_id, room_or_id)
      user = lock_active!(user_or_id)
      room_id = room_or_id.respond_to?(:id) ? room_or_id.id : room_or_id
      room = Room.lock.find(room_id)
      membership = Membership.lock.find_by(room_id: room.id, user_id: user.id)
      unless membership && (user.administrator? || room.creator_id == user.id || room.direct?)
        raise AuthorizationError, "user cannot administer this room"
      end
      [ user, room ]
    rescue ActiveRecord::RecordNotFound
      raise AuthorizationError, "room is not available"
    end

    def lock_room_creator!(user_or_id)
      user = lock_active!(user_or_id)
      account = Account.lock.sole
      if account.settings.restrict_room_creation_to_administrators? && !user.administrator?
        raise AuthorizationError, "user cannot create rooms"
      end
      user
    end
  end

  def initials
    name.scan(/\b\w/).join
  end

  def title
    [ name, bio ].compact_blank.join(" – ")
  end

  def deactivate_by!(actor:)
    MutationFence.with(id) do
      self.class.transaction do
        self.class.lock_administrator! actor
        self.class.lock_active!(id).send :deactivate!
      end
    end
    disconnect_remote_connections
  end

  def deactivate_from_identity_provider!(identity:, issuer:)
    changed = false
    MutationFence.with(id) do
      self.class.transaction do
        user = self.class.lock.find(id)
        current_identity = user.identities.lock.find_by!(
          id: identity.id, user_id: user.id, issuer:, subject: identity.subject, scim_id: identity.scim_id
        )
        current_identity.update!(provider_revoked_at: Time.current) unless current_identity.provider_revoked_at?
        if user.active?
          user.send :deactivate!
          changed = true
        else
          changed = user.sessions.exists? || user.push_subscriptions.exists? ||
            user.searches.exists? || user.memberships.without_direct_rooms.exists?
          user.send :remove_deprovisioned_access!
        end
      end
    end
    disconnect_remote_connections if changed
    reload
  end

  def update_role_by!(attributes, actor:)
    MutationFence.with(id) do
      self.class.transaction do
        self.class.lock_administrator! actor
        self.class.lock_active!(id).update!(attributes)
      end
    end
    reload
  end

  def disconnect_remote_connections(reconnect: false)
    close_remote_connections reconnect:
  end

  private
    def normalize_email_identity
      normalized_email_address = self.class.normalize_email_address(email_address)
      self.email_address = normalized_email_address
      self.normalized_email_address = normalized_email_address
    end

    def deactivate!
      with_lock do
        apply_deactivation!
      end
    end

    def apply_deactivation!
      update! status: :deactivated, email_address: deactived_email_address
      remove_deprovisioned_access!
    end

    def remove_deprovisioned_access!
      memberships.without_direct_rooms.delete_all
      push_subscriptions.delete_all
      searches.delete_all
      sessions.delete_all
    end

    def grant_membership_to_open_rooms
      Membership.insert_all(Rooms::Open.pluck(:id).collect { |room_id| { room_id: room_id, user_id: id } })
    end

    def deactived_email_address
      email_address&.gsub(/@/, "-deactivated-#{SecureRandom.uuid}@")
    end

    def close_remote_connections(reconnect: false)
      ActionCable.server.remote_connections.where(current_user: self).disconnect reconnect:
    rescue StandardError => error
      Rails.logger.error "Failed to disconnect Action Cable user_id=#{id} error=#{error.class.name}"
    end

    def preserve_required_recovery_binding
      return unless (Oidc.required? || Oidc.rollback_prepared?) && Account.where(oidc_break_glass_user_id: id).exists?
      return unless will_save_change_to_email_address? || will_save_change_to_role? || will_save_change_to_status?

      errors.add :base, "the required-mode recovery administrator must be rotated before this account changes"
    end
end
