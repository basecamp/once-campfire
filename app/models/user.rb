class User < ApplicationRecord
  include Avatar, Bot, Mentionable, Role, Transferable

  has_many :memberships, dependent: :delete_all
  has_many :rooms, through: :memberships

  has_many :reachable_messages, through: :rooms, source: :messages
  has_many :messages, dependent: :destroy, foreign_key: :creator_id

  has_many :push_subscriptions, class_name: "Push::Subscription", dependent: :delete_all

  has_many :boosts, dependent: :destroy, foreign_key: :booster_id
  has_many :searches, dependent: :delete_all

  has_many :sessions, dependent: :destroy

  scope :active, -> { where(active: true) }

  has_secure_password validations: false

  after_create_commit :grant_membership_to_open_rooms

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

      update! active: false, email_address: deactived_email_address
    end
  end

  def deactivated?
    !active?
  end

  def reset_remote_connections
    close_remote_connections reconnect: true
  end

  def lock_out!
    transaction do
      close_remote_connections
      sessions.delete_all
      update!(active: false, email_address: deactived_email_address)
    end
  end

  def unlock!
    transaction do
      update!(active: true)
      # Restore original email if it was deactivated
      if email_address&.include?("-deactivated-")
        original_email = email_address.gsub(/-deactivated-[^@]+@/, "@")
        update!(email_address: original_email) if original_email != email_address
      end
    end
  end

  def censor_messages!
    transaction do
      messages.find_each do |message|
        if message.body.present?
          message.body.update!(body: "[Message content removed by administrator]")
        end
      end
    end
  end

  def admin_delete!(censor_messages: false)
    transaction do
      if censor_messages
        censor_messages!
      else
        messages.destroy_all
      end

      # Remove from all rooms except direct rooms
      memberships.without_direct_rooms.delete_all

      # Clean up other associations
      push_subscriptions.delete_all
      searches.delete_all
      sessions.delete_all
      boosts.destroy_all

      # Deactivate the user
      update!(active: false, email_address: deactived_email_address)
    end
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
end
