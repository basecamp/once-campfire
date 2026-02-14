class User < ApplicationRecord
  include Avatar, Bannable, Bot, Mentionable, Role, Transferable

  has_many :memberships, dependent: :delete_all
  has_many :rooms, through: :memberships

  has_many :reachable_messages, through: :rooms, source: :messages
  has_many :messages, dependent: :destroy, foreign_key: :creator_id

  has_many :push_subscriptions, class_name: "Push::Subscription", dependent: :delete_all

  has_many :boosts, dependent: :destroy, foreign_key: :booster_id
  has_many :searches, dependent: :delete_all

  has_many :sessions, dependent: :destroy
  has_many :bans, dependent: :destroy

  enum :status, %i[ active deactivated banned ], default: :active

  has_secure_password validations: false

  after_create_commit :grant_membership_to_open_rooms
  after_update_commit :broadcast_profile_update, if: :should_broadcast_profile_update?

  scope :ordered, -> { order("LOWER(name)") }
  scope :filtered_by, ->(query) { where("name like ?", "%#{query}%") }

  def initials
    name.scan(/\b\w/).join
  end

  def title
    [ name, bio ].compact_blank.join(" – ")
  end

  def deactivate
    transaction do
      close_remote_connections

      memberships.without_direct_rooms.delete_all
      push_subscriptions.delete_all
      searches.delete_all
      sessions.delete_all

      update! status: :deactivated, email_address: deactived_email_address
    end
  end

  def reset_remote_connections
    close_remote_connections reconnect: true
  end

  private
    def grant_membership_to_open_rooms
      Membership.insert_all(Rooms::Open.pluck(:id).collect { |room_id| { room_id: room_id, user_id: id } })
    end

    def deactived_email_address
      email_address&.gsub(/@/, "-deactivated-#{SecureRandom.uuid}@")
    end

    def close_remote_connections(reconnect: false)
      ActionCable.server.remote_connections.where(current_user: self).disconnect reconnect: reconnect
    end

    def should_broadcast_profile_update?
      saved_change_to_name? || saved_change_to_avatar_token? || saved_change_to_avatar?
    end

    def broadcast_profile_update
      # Broadcast to all direct rooms this user is a member of
      # This will update the avatar/name in the sidebar for other users
      # OPTIMIZED: Preload associations to avoid N+1 queries
      rooms.directs.includes(:users, :memberships).find_each do |room|
        memberships_by_user = room.memberships.index_by(&:user_id)

        room.users.without(self).find_each do |other_user|
          membership = memberships_by_user[other_user.id]
          if membership
            html = ApplicationController.render(
              partial: "users/sidebars/rooms/direct",
              locals: { membership: membership }
            )
            broadcast_replace_to other_user, :rooms, target: dom_id(room, :list), html: html
          end
        end
      end
    rescue => e
      Rails.logger.error "Failed to broadcast profile update: #{e.message}"
    end
end
