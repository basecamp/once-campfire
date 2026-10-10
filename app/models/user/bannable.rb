module User::Bannable
  extend ActiveSupport::Concern

  included do
    # Administrators still see banned users, so they can lift the ban.
    scope :visible_to, ->(user) { user.can_administer? ? where(status: %i[ active banned ]) : active }
  end

  def ban
    transaction do
      create_bans_from_sessions
      apply_ban
      banned!
    end
  end

  def unban
    transaction do
      bans.delete_all
      active!
    end
  end

  def remove_banned_content_later
    RemoveBannedContentJob.perform_later(self)
  end

  def remove_banned_content
    messages.each do |message|
      message.destroy
      message.broadcast_remove
    end
  end

  private
    # Ban refuses private and internal addresses. Those are skipped, and the user is banned regardless.
    # Kept out of the bans association, where a refused ban would fail saving the user.
    def create_bans_from_sessions
      sessions.pluck(:ip_address).compact_blank.uniq.each do |ip|
        Ban.create(user: self, ip_address: ip)
      end
    end

    def apply_ban
      close_remote_connections
      sessions.delete_all
      remove_banned_content_later
    end
end
