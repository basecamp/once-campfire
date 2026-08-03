module User::Bannable
  extend ActiveSupport::Concern

  def ban_by!(actor:)
    User::MutationFence.with(id) do
      self.class.transaction do
        self.class.lock_administrator! actor
        self.class.lock.find(id).send :apply_ban!
      end
    end
  end

  def unban_by!(actor:)
    User::MutationFence.with(id) do
      self.class.transaction do
        self.class.lock_administrator! actor
        user = self.class.uncached { self.class.lock.find(id) }
        raise User::AuthorizationError, "user is not banned" unless user.banned?

        user.send :remove_ban!
      end
    end
  end

  private
    def apply_ban!
      with_lock do
        create_bans_from_sessions
        self.ban_cleanup_generation += 1
        self.status = :banned
        save!
        apply_ban
        ban_cleanup_intents.create!(generation: ban_cleanup_generation)
      end
    end

    def remove_ban!
      with_lock do
        bans.delete_all
        if identities.where.not(provider_revoked_at: nil).exists?
          send :apply_deactivation!
        else
          self.status = :active
          save!
        end
        now = Time.current
        ban_cleanup_intents.pending.where(purge_started_at: nil).update_all(
          canceled_at: now, lease_token: nil, enqueued_at: nil, started_at: nil,
          next_attempt_at: nil, updated_at: now
        )
      end
    end

    def create_bans_from_sessions
      sessions.pluck(:ip_address).compact_blank.uniq.each do |ip|
        bans.create!(ip_address: ip) if Ban.public_ip_address?(ip)
      end
    end

    def apply_ban
      push_subscriptions.delete_all
      sessions.destroy_all
    end
end
