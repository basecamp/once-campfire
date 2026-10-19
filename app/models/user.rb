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
  validate :password_challenge_matches, unless: -> { password_challenge.nil? }

  after_create_commit :grant_membership_to_open_rooms
  after_update :sign_out_all_sessions, if: :saved_change_to_password_digest?

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
    # The profile sets password_challenge whenever it changes the password; scripts that reset one don't.
    def password_challenge_matches
      unless password_digest_was.present? && BCrypt::Password.new(password_digest_was).is_password?(password_challenge)
        errors.add :password_challenge, :invalid
      end
    end

    # A new password is how someone shuts out whoever else got into their account, so it ends every session, copies
    # of the changing browser's cookie included, and every push subscription; browsers still signed in post theirs
    # again. Connections close once that commits, registered on the transaction because a later save in it would
    # replace the saved change an after_commit condition reads.
    def sign_out_all_sessions
      sessions.delete_all
      push_subscriptions.delete_all
      self.class.current_transaction.after_commit { disconnect_signed_out_sessions }
    end

    # The password is saved by now, so a realtime service that can't be reached mustn't fail the change.
    def disconnect_signed_out_sessions
      reset_remote_connections
    rescue => error
      Rails.logger.warn "Could not disconnect remote connections after a password change: #{error.class}"
    end

    # One statement, which SQLite runs under the write lock, so no room is closed between reading the open ones and
    # inserting. A room that Room#destroy_later closes is either closed before, and skipped, or after, and takes this
    # membership away with the others. A room that granted itself to every user when it was created is skipped too,
    # as insert_all did.
    def grant_membership_to_open_rooms
      now = Time.current

      Membership.connection.execute Membership.sanitize_sql([ <<~SQL, id, now, now ])
        insert into memberships (room_id, user_id, created_at, updated_at)
        select id, ?, ?, ? from rooms where type = 'Rooms::Open'
        on conflict do nothing
      SQL
    end

    def deactived_email_address
      email_address&.gsub(/@/, "-deactivated-#{SecureRandom.uuid}@")
    end

    def close_remote_connections(reconnect: false)
      ActionCable.server.remote_connections.where(current_user: self).disconnect reconnect: reconnect
    end
end
