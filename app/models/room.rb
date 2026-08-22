class Room < ApplicationRecord
  DIRECT_TYPE = "Rooms::Direct"

  has_many :memberships, dependent: :delete_all do
    def grant_to(users)
      room = proxy_association.owner
      room.send :ensure_membership_changes_allowed!
      Membership.insert_all(Array(users).collect { |user| { room_id: room.id, user_id: user.id, involvement: room.default_involvement } })
    end

    def revoke_from(users)
      proxy_association.owner.send :ensure_membership_changes_allowed!
      destroy_by user: users
    end

    def revise(granted: [], revoked: [])
      proxy_association.owner.send :ensure_membership_changes_allowed!
      transaction do
        grant_to(granted) if granted.present?
        revoke_from(revoked) if revoked.present?
      end
    end

    def delete(...)
      proxy_association.owner.send :ensure_membership_changes_allowed!
      super
    end

    def delete_all(...)
      proxy_association.owner.send :ensure_membership_changes_allowed!
      super
    end

    def destroy(...)
      proxy_association.owner.send :ensure_membership_changes_allowed!
      super
    end

    def destroy_all(...)
      proxy_association.owner.send :ensure_membership_changes_allowed!
      super
    end
  end

  has_many :users, through: :memberships do
    def <<(...)
      proxy_association.owner.send :ensure_membership_changes_allowed!
      super
    end

    def concat(...)
      proxy_association.owner.send :ensure_membership_changes_allowed!
      super
    end

    def delete(...)
      proxy_association.owner.send :ensure_membership_changes_allowed!
      super
    end

    def delete_all(...)
      proxy_association.owner.send :ensure_membership_changes_allowed!
      super
    end

    def destroy(...)
      proxy_association.owner.send :ensure_membership_changes_allowed!
      super
    end

    def destroy_all(...)
      proxy_association.owner.send :ensure_membership_changes_allowed!
      super
    end

    def clear(...)
      proxy_association.owner.send :ensure_membership_changes_allowed!
      super
    end
  end
  has_many :messages, dependent: :destroy

  belongs_to :creator, class_name: "User", default: -> { Current.user }

  validate :preserve_direct_identity, on: :update

  scope :opens,           -> { where(type: "Rooms::Open") }
  scope :closeds,         -> { where(type: "Rooms::Closed") }
  scope :directs,         -> { where(type: "Rooms::Direct") }
  scope :without_directs, -> { where.not(type: "Rooms::Direct") }

  scope :ordered, -> { order("LOWER(name)") }

  class << self
    def create_for(attributes, users:, actor: nil)
      transaction do
        creator = actor ? User.lock_room_creator!(actor) : attributes[:creator]
        create!(attributes.merge(creator: creator).compact).tap do |room|
          room.memberships.grant_to(room.open? ? User.active : users)
        end
      end
    end

    def original
      order(:created_at).first
    end
  end

  def receive(message)
    memberships.visible.where.not(user: message.creator)
      .where(created_at: ..message.created_at)
  end

  def destroy
    @destroying_with_memberships = true
    super
  ensure
    @destroying_with_memberships = false
  end

  def user_ids=(...)
    ensure_membership_changes_allowed!
    super
  end

  def users=(...)
    ensure_membership_changes_allowed!
    super
  end

  def open?
    is_a?(Rooms::Open)
  end

  def closed?
    is_a?(Rooms::Closed)
  end

  def direct?
    is_a?(Rooms::Direct)
  end

  def default_involvement
    "mentions"
  end

  def update_as_open!(attributes, actor:)
    transaction do
      _, room = User.lock_room_administrator!(actor, id)
      room.update!(attributes.merge(type: "Rooms::Open"))
      room.memberships.grant_to User.active
    end
    reload
  end

  def update_as_closed!(attributes, user_ids:, actor:)
    user_ids = Array(user_ids).map(&:to_i).uniq
    with_revoked_bot_fences(user_ids) do
      transaction do
        _, room = User.lock_room_administrator!(actor, id)
        room.update!(attributes.merge(type: "Rooms::Closed"))
        room.memberships.revise(
          granted: User.where(id: user_ids),
          revoked: room.users.where.not(id: user_ids)
        )
      end
    end
    reload
  end

  def destroy_by!(actor:)
    with_bot_member_fences do
      transaction do
        _, room = User.lock_room_administrator!(actor, id)
        room.destroy!
      end
    end
    self
  end

  private
    def ensure_membership_changes_allowed!
      if immutable_direct_room? && !destroying_with_memberships?
        raise Rooms::Direct::ParticipantMutationError, "direct room participants are immutable"
      end
    end

    def immutable_direct_room?
      type == DIRECT_TYPE || attribute_in_database("type") == DIRECT_TYPE
    end

    def preserve_direct_identity
      if will_save_change_to_type? && [ type, attribute_in_database("type") ].include?(DIRECT_TYPE)
        errors.add :type, "cannot be changed for a direct room"
      end
      if direct_participant_key_in_database.present? && will_save_change_to_direct_participant_key?
        errors.add :direct_participant_key, "cannot be changed"
      end
    end

    def destroying_with_memberships?
      @destroying_with_memberships == true
    end

    def with_revoked_bot_fences(retained_user_ids, &block)
      candidates = -> {
        memberships.joins(:user).merge(User.where(role: :bot))
          .where.not(user_id: retained_user_ids).pluck(:user_id)
      }
      with_stable_bot_fences(candidates, &block)
    end

    def with_bot_member_fences(&block)
      candidates = -> { memberships.joins(:user).merge(User.where(role: :bot)).pluck(:user_id) }
      with_stable_bot_fences(candidates, &block)
    end

    def with_stable_bot_fences(candidates)
      fence_ids = candidates.call
      loop do
        missing_ids = []
        completed = User::MutationFence.with(fence_ids) do
          self.class.transaction do
            missing_ids = candidates.call - fence_ids
            next false if missing_ids.any?

            yield
            true
          end
        end
        return if completed

        fence_ids |= missing_ids
      end
    end
end
