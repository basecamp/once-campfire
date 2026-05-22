class Membership < ApplicationRecord
  include Connectable

  belongs_to :room
  belongs_to :user

  after_destroy_commit { user.reset_remote_connections }

  enum :involvement, %w[ invisible nothing mentions everything ].index_by(&:itself), prefix: :involved_in

  scope :with_ordered_room, -> { includes(:room).joins(:room).order("LOWER(rooms.name)") }
  scope :without_direct_rooms, -> { joins(:room).where.not(room: { type: "Rooms::Direct" }) }

  scope :visible, -> { where.not(involvement: :invisible) }
  scope :unread,  -> { where.not(unread_at: nil) }

  def self.online_user_lookup(user_ids = nil)
    relation = connected.distinct
    relation = relation.where(user_id: user_ids) if user_ids

    relation.pluck(:user_id).index_with(true)
  end

  def read
    update!(unread_at: nil)
  end

  def unread?
    unread_at.present?
  end
end
