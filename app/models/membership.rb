class Membership < ApplicationRecord
  include Connectable

  belongs_to :room
  belongs_to :user

  after_destroy_commit { user.reset_remote_connections }

  enum :involvement, %w[ invisible nothing mentions everything ].index_by(&:itself), prefix: :involved_in

  scope :with_ordered_room, -> { includes(:room).joins(:room).order("LOWER(rooms.name)") }
  scope :with_direct_rooms, -> { includes(:room).joins(:room).merge(Room.directs).order(rooms: { updated_at: :desc }) }
  scope :without_direct_rooms, -> { joins(:room).merge(Room.without_directs) }

  scope :visible, -> {
    # Avoid joins here so callers can still use Relation#or (joins break structural compatibility).
    where.not(involvement: :invisible).where(room_id: Room.active.select(:id))
  }
  scope :unread,  -> { where.not(unread_at: nil) }

  def read
    update!(unread_at: nil)
  end

  def unread?
    unread_at.present?
  end
end
