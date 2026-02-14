class Membership < ApplicationRecord
  include Connectable

  belongs_to :room
  belongs_to :user

  after_destroy_commit :broadcast_membership_removed
  after_create_commit :broadcast_membership_added

  enum :involvement, %w[ invisible nothing mentions everything ].index_by(&:itself), prefix: :involved_in

  scope :with_ordered_room, -> { includes(:room).joins(:room).order("LOWER(rooms.name)") }
  scope :without_direct_rooms, -> { joins(:room).where.not(room: { type: "Rooms::Direct" }) }

  scope :visible, -> { where.not(involvement: :invisible) }
  scope :unread,  -> { where.not(unread_at: nil) }

  def read
    update!(unread_at: nil)
  end

  def unread?
    unread_at.present?
  end

  private
    def broadcast_membership_added
      # For direct rooms, update the direct rooms list for both users
      if room.direct?
        # OPTIMIZED: Single query with caching to avoid N+1
        memberships_by_user = room.memberships.index_by(&:user_id)

        room.users.find_each do |room_user|
          membership = memberships_by_user[room_user.id]
          next unless membership

          html = ApplicationController.render(
            partial: "users/sidebars/rooms/direct",
            locals: { membership: membership }
          )
          broadcast_replace_to room_user, :rooms, target: dom_id(room, :list), html: html
        end
      else
        # For shared rooms, add to shared_rooms list
        html = ApplicationController.render(
          partial: "users/sidebars/rooms/shared",
          locals: { room: room, unread: false, current_room: nil }
        )
        broadcast_prepend_to user, :rooms, target: :shared_rooms, html: html
      end
    rescue => e
      Rails.logger.error "Failed to broadcast membership added: #{e.message}"
    end

    def broadcast_membership_removed
      # Remove room from sidebar for the user who left
      broadcast_remove_to user, :rooms, target: dom_id(room, :list)
      
      # For direct rooms, also update the other user's sidebar
      if room.direct?
        other_user = room.users.without(user).first
        if other_user
          # Remove the direct room from the other user's sidebar too
          broadcast_remove_to other_user, :rooms, target: dom_id(room, :list)
        end
      end
      
      user.reset_remote_connections
    rescue => e
      Rails.logger.error "Failed to broadcast membership removed: #{e.message}"
    end
end
