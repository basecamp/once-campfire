class Room < ApplicationRecord
  has_many :memberships, dependent: :delete_all do
    def grant_to(users)
      room = proxy_association.owner
      Membership.insert_all(Array(users).collect { |user| { room_id: room.id, user_id: user.id, involvement: room.default_involvement } })
    end

    def revoke_from(users)
      destroy_by user: users
    end

    def revise(granted: [], revoked: [])
      transaction do
        grant_to(granted) if granted.present?
        revoke_from(revoked) if revoked.present?
      end
    end
  end

  has_many :users, through: :memberships
  has_many :messages, dependent: :destroy

  belongs_to :creator, class_name: "User", default: -> { Current.user }

  validate :direct_rooms_keep_their_type, on: :update

  scope :opens,           -> { where(type: "Rooms::Open") }
  scope :closeds,         -> { where(type: "Rooms::Closed") }
  scope :directs,         -> { where(type: "Rooms::Direct") }
  scope :without_directs, -> { where.not(type: "Rooms::Direct") }

  scope :ordered, -> { order("LOWER(name)") }

  class << self
    def create_for(attributes, users:)
      transaction do
        create!(attributes).tap do |room|
          room.memberships.grant_to users
        end
      end
    end

    def original
      order(:created_at).first
    end
  end

  # Takes the room away from its members at once, and leaves its messages to Room::DestroyJob. Destroying them in
  # the room's own transaction held the database's write lock, and stopped every other write, until the last one.
  # An open room is closed first, so that no one who joins the account before the job runs is let in.
  def destroy_later
    room = open? ? becomes!(Rooms::Closed) : self

    former_member_ids = transaction do
      room.save!
      room.memberships.pluck(:user_id).tap { room.memberships.delete_all }
    end

    Room::DestroyJob.perform_later(room, former_member_ids)
  end

  # Deleting the memberships skips the reset that revoking one does, so the former members get it here, all at once,
  # before the messages go: their connections stop receiving the room's streams. It's done in the job, not the
  # request, because it costs a cache-store round trip per member.
  def reset_remote_connections_of(user_ids)
    User.where(id: user_ids).find_each(&:reset_remote_connections)
  end

  # Each message is destroyed in its own transaction, so other writes get through in between. Any message posted
  # meanwhile goes with the room.
  def destroy_one_message_at_a_time
    messages.find_each(&:destroy)
    destroy
  end

  def receive(message)
    unread_memberships(message)
    push_later(message)
  end

  # Rewriting every member on every message is most of what posting to a large room writes,
  # so members who are unread already stay as they are. Directs keep touching them all: a
  # direct's sidebar row is cached by membership and shows the room's recency.
  def unread_memberships(message)
    recipients = memberships.visible.disconnected.where.not(user: message.creator)
    recipients = recipients.where(unread_at: nil) unless direct?
    recipients.update_all(unread_at: message.created_at, updated_at: Time.current)
  end

  def push_later(message)
    Room::PushMessageJob.perform_later(self, message)
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

  private
    # Open and closed rooms convert into each other freely. A direct room can't become
    # either: its participants agreed to a private conversation, not to one whose
    # audience someone else gets to widen afterwards.
    def direct_rooms_keep_their_type
      if type_changed? && type_was == "Rooms::Direct"
        errors.add :type, "can't be changed for a direct room"
      end
    end
end
